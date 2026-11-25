import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/semester/current_term_resolver.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';
import '../../helpers/credential_store_test_ext.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const examEndpoint = '/jwglxt/kwgl/kscx_cxXsksxxIndex.html';
  const termEndpoint = '/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html';

  String dateText(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  final firstExamDate = dateText(DateTime.now().add(const Duration(days: 14)));
  final secondExamDate = dateText(DateTime.now().add(const Duration(days: 30)));

  final sampleItems = [
    {
      'kcmc': '高等数学',
      'kch': 'MATH101',
      'kssj': '第5周 周三($firstExamDate) 14:00-16:00',
      'cdmc': '教学楼A301',
      'cdxqmc': '本部',
      'zwh': '15',
      'ksmc': '期末考试',
      'kkxy': '理学院',
      'cxbj': '',
      'xnmc': '2025-2026',
      'xqmmc': '第二学期',
    },
    {
      'kcmc': '大学物理',
      'kch': 'PHY101',
      'kssj': '第8周 周一($secondExamDate) 09:00-11:00',
      'cdmc': '实验楼B201',
      'cdxqmc': '本部',
      'zwh': '',
      'ksmc': '',
      'kkxy': '',
      'cxbj': '',
      'xnmc': '2025-2026',
      'xqmmc': '第二学期',
    },
  ];

  ResponseBody jsonBody(Object? data, {int statusCode = 200}) {
    return ResponseBody.fromString(
      jsonEncode(data),
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(condition(), isTrue, reason: 'condition not met in time');
  }

  setUp(() async {
    // 认证持久化（AuthSessionPersistence）依赖 path_provider。
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationSupportDirectory') {
        return Directory.systemTemp.path;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(pathProviderChannel, null),
    );
    await resetTestEnvironment();
    ConnectModeResolver.instance.directReachabilityChecker = () async => true;
    await CurrentTermResolver.instance.debugReset();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
  });

  Future<int> durableEpoch() async =>
      (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.academic,
      )).epoch;

  Future<int> loginAcademic(String account) async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: account);
    await CredentialStore.instance.saveZhengfangSession(account);
    return durableEpoch();
  }

  Future<void> seedEnvelope({
    required String owner,
    required int epoch,
    required DateTime savedAt,
    Object? items,
  }) async {
    final store = SharedPreferencesPrivateCacheStore(ExamService.cacheKey);
    await store.write(
      PrivateCacheEnvelope(
        owner: owner,
        updatedAt: savedAt,
        epoch: epoch,
        payload: items ?? sampleItems,
      ),
    );
  }

  Future<void> seedLegacy({
    required DateTime savedAt,
    String? owner,
    Object? items,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('exam_cached_data', jsonEncode(items ?? sampleItems));
    await prefs.setInt('exam_cached_at', savedAt.millisecondsSinceEpoch);
    if (owner != null) await prefs.setString('exam_cached_owner', owner);
  }

  MockHttpClientAdapter loggedInAdapter({Object? items}) {
    return MockHttpClientAdapter()
      ..registerText(
        'GET',
        termEndpoint,
        '<select id="xnm"><option value="2025" selected>x</option></select>'
            '<select id="xqm"><option value="12" selected>y</option></select>',
      )
      ..registerJson('POST', examEndpoint, {'items': items ?? sampleItems});
  }

  group('ExamService.restoreCache', () {
    test('restores exams for the current durable epoch + owner', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());

      final restored = await ExamService.instance.restoreCache();

      expect(restored, isTrue);
      expect(ExamService.instance.cachedExams, isNotNull);
      expect(ExamService.instance.cachedExams, hasLength(2));
      expect(ExamService.instance.cachedExams!.first.courseName, '高等数学');
    });

    test('returns false when no cache exists', () async {
      await loginAcademic('A');

      final restored = await ExamService.instance.restoreCache();

      expect(restored, isFalse);
      expect(ExamService.instance.cachedExams, isNull);
    });

    test('sorts exams by date during restore', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now(),
        items: [sampleItems[1], sampleItems[0]],
      );

      await ExamService.instance.restoreCache();

      expect(ExamService.instance.cachedExams!.first.courseName, '高等数学');
    });

    test('restore without an explicit identity does not fall back', () async {
      await seedEnvelope(owner: 'A', epoch: 1, savedAt: DateTime.now());

      expect(await ExamService.instance.restoreCache(), isFalse);
      expect(ExamService.instance.cachedExams, isNull);
    });

    test('restore with an old durable epoch is not shown', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      expect(await ExamService.instance.restoreCache(), isTrue);

      await CredentialStore.instance.saveZhengfangSession('A');
      ExamService.instance.debugReset();

      expect(await ExamService.instance.restoreCache(), isFalse);
      expect(ExamService.instance.cachedExams, isNull);
    });

    test('restore completing after same-account re-login does not adopt old record', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());

      ExamService.instance.debugRestoreBarrier = () async {
        await ZhengfangAuth.instance.markLoggedOut();
        ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
        await ZhengfangAuth.instance.markLoggedIn();
      };

      expect(await ExamService.instance.restoreCache(), isFalse);
      expect(ExamService.instance.cachedExams, isNull);
      expect(ExamService.instance.nextExam, isNull);
    });

    test(
      'getter returns null after same-account re-login without new fetch',
      () async {
        final epoch = await loginAcademic('A');
        await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
        await ExamService.instance.restoreCache();
        expect(ExamService.instance.cachedExams, isNotNull);

        await ZhengfangAuth.instance.markLoggedOut();
        ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
        await ZhengfangAuth.instance.markLoggedIn();

        expect(ExamService.instance.cachedExams, isNull);
        expect(ExamService.instance.nextExam, isNull);
      },
    );

    test(
      'stale in-memory record is dropped once a new durable epoch is observed',
      () async {
        final epoch = await loginAcademic('A');
        await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
        await ExamService.instance.restoreCache();
        expect(ExamService.instance.cachedExams, isNotNull);

        await CredentialStore.instance.saveZhengfangSession('A');
        expect(await ExamService.instance.restoreCache(), isFalse);
        expect(ExamService.instance.cachedExams, isNull);
      },
    );

    test('legacy multi-key cache is discarded, not migrated', () async {
      await loginAcademic('A');
      await seedLegacy(savedAt: DateTime.now(), owner: 'A');

      expect(await ExamService.instance.restoreCache(), isFalse);
      expect(ExamService.instance.cachedExams, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('exam_cached_data'), isNull);
      expect(prefs.getInt('exam_cached_at'), isNull);
      expect(prefs.getString('exam_cached_owner'), isNull);
      final store = SharedPreferencesPrivateCacheStore(ExamService.cacheKey);
      expect(await store.read(), isNull);
    });

    test('another account cache is never shown as current', () async {
      await loginAcademic('B');
      await seedEnvelope(owner: 'A', epoch: 1, savedAt: DateTime.now());

      expect(await ExamService.instance.restoreCache(), isFalse);
      expect(ExamService.instance.cachedExams, isNull);
    });
  });

  group('ExamService accessors', () {
    test('nextExam returns first upcoming exam', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      await ExamService.instance.restoreCache();

      final next = ExamService.instance.nextExam;

      expect(next, isNotNull);
      expect(next!.courseName, '高等数学');
    });

    test('nextExam returns null when no cache', () {
      expect(ExamService.instance.nextExam, isNull);
    });

    test('nextExam hides the previous account cache after a switch', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      await ExamService.instance.restoreCache();
      expect(ExamService.instance.nextExam, isNotNull);

      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'B');

      expect(ExamService.instance.nextExam, isNull);
    });
  });

  group('ExamService identity gate', () {
    test('not logged in sends no request', () async {
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        ExamService.instance.fetchExams(),
        throwsA(
          isA<ExamAuthExpiredException>().having(
            (e) => e.automaticLoginPaused,
            'automaticLoginPaused',
            isFalse,
          ),
        ),
      );
      expect(adapter.requestLog, isEmpty);
      expect(ExamService.instance.cachedExams, isNull);
    });

    test('logged in as A but passing B sends no request', () async {
      await loginAcademic('A');
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        ExamService.instance.fetchExams(studentId: 'B'),
        throwsA(isA<ExamRequestException>()),
      );
      expect(adapter.requestLog, isEmpty);
    });

    test('blank explicit student id sends no request', () async {
      await loginAcademic('A');
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        ExamService.instance.fetchExams(studentId: '  '),
        throwsA(isA<ExamRequestException>()),
      );
      expect(adapter.requestLog, isEmpty);
    });

    test('in-memory identity without durable session fails closed', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        ExamService.instance.fetchExams(),
        throwsA(isA<ExamAuthExpiredException>()),
      );
      expect(adapter.requestLog, isEmpty);
    });
  });

  group('ExamService TTL and request ordering', () {
    test('fresh cache is served without touching the network', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      await ExamService.instance.restoreCache();

      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ExamService.instance.fetchExams();

      expect(result, hasLength(2));
      expect(adapter.requestLog, isEmpty);
    });

    test('expired cache triggers a refetch', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now().subtract(const Duration(minutes: 16)),
      );
      await ExamService.instance.restoreCache();
      expect(ExamService.instance.isCacheFresh, isFalse);
      expect(ExamService.instance.isStale, isTrue);

      final adapter = loggedInAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ExamService.instance.fetchExams();

      expect(adapter.requestLog, contains('POST $examEndpoint'));
      expect(result, hasLength(2));
    });

    test('forceRefresh bypasses a fresh cache', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      await ExamService.instance.restoreCache();

      final adapter = loggedInAdapter(items: [sampleItems[0]]);
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ExamService.instance.fetchExams(forceRefresh: true);

      expect(adapter.requestLog, contains('POST $examEndpoint'));
      expect(result, hasLength(1));
    });

    test('late result is dropped after same-account re-login', () async {
      await loginAcademic('A');
      await ZhengfangAuth.instance.markLoggedIn();

      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = MockHttpClientAdapter()
        ..registerText('GET', termEndpoint, '<html></html>')
        ..register('POST', examEndpoint, (options) {
          if (!started.isCompleted) started.complete();
          return response.future;
        });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final future = ExamService.instance.fetchExams(forceRefresh: true);
      await started.future;

      await ZhengfangAuth.instance.markLoggedOut();
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      await ZhengfangAuth.instance.markLoggedIn();

      response.complete(jsonBody({'items': sampleItems}));

      await expectLater(future, throwsA(isA<ExamRequestException>()));
      expect(ExamService.instance.cachedExams, isNull);
      expect(ExamService.instance.nextExam, isNull);
    });

    test('durable revoke during in-flight request discards result', () async {
      await loginAcademic('A');

      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = MockHttpClientAdapter()
        ..registerText('GET', termEndpoint, '<html></html>')
        ..register('POST', examEndpoint, (options) {
          if (!started.isCompleted) started.complete();
          return response.future;
        });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final future = ExamService.instance.fetchExams(forceRefresh: true);
      await started.future;

      await AuthSessionPersistence.instance.revoke(
        CredentialSessionDomain.academic,
      );

      response.complete(jsonBody({'items': sampleItems}));

      await expectLater(future, throwsA(isA<ExamAuthExpiredException>()));
      final store = SharedPreferencesPrivateCacheStore(ExamService.cacheKey);
      expect(await store.read(), isNull);
    });

    test(
      'locked write then re-login: new epoch does not read old record',
      () async {
        final epoch = await loginAcademic('A');

        final adapter = loggedInAdapter();
        DioClient.instance.dio.httpClientAdapter = adapter;
        await ExamService.instance.fetchExams(forceRefresh: true);

        final store = SharedPreferencesPrivateCacheStore(ExamService.cacheKey);
        final record = await store.read();
        expect(record, isNotNull);
        expect(record!.epoch, epoch);

        await CredentialStore.instance.saveZhengfangSession('A');
        ExamService.instance.debugReset();

        expect(await ExamService.instance.restoreCache(), isFalse);
      },
    );

    test('concurrent identical fetches share one request', () async {
      await loginAcademic('A');

      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      var calls = 0;
      final adapter = MockHttpClientAdapter()
        ..registerText('GET', termEndpoint, '<html></html>')
        ..register('POST', examEndpoint, (options) {
          calls += 1;
          if (!started.isCompleted) started.complete();
          return response.future;
        });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final first = ExamService.instance.fetchExams(forceRefresh: true);
      final second = ExamService.instance.fetchExams(forceRefresh: true);
      await started.future;
      expect(calls, 1);

      response.complete(jsonBody({'items': sampleItems}));

      expect(await first, hasLength(2));
      expect(await second, hasLength(2));
      expect(calls, 1);
    });

    test('non-force shares an in-flight force request', () async {
      await loginAcademic('A');

      final response = Completer<ResponseBody>();
      var calls = 0;
      final adapter = MockHttpClientAdapter()
        ..registerText('GET', termEndpoint, '<html></html>')
        ..register('POST', examEndpoint, (options) {
          calls += 1;
          return response.future;
        });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final forced = ExamService.instance.fetchExams(forceRefresh: true);
      final nonForce = ExamService.instance.fetchExams();
      await waitFor(() => calls == 1);

      response.complete(jsonBody({'items': sampleItems}));

      expect(await forced, hasLength(2));
      expect(await nonForce, hasLength(2));
      expect(calls, 1);
    });

    test(
      'force starts a newer request; stale non-force cannot overwrite',
      () async {
        await loginAcademic('A');

        final slow = Completer<ResponseBody>();
        final fast = Completer<ResponseBody>();
        var calls = 0;
        final adapter = MockHttpClientAdapter()
          ..registerText('GET', termEndpoint, '<html></html>')
          ..register('POST', examEndpoint, (options) {
            calls += 1;
            return calls == 1 ? slow.future : fast.future;
          });
        DioClient.instance.dio.httpClientAdapter = adapter;

        final nonForce = ExamService.instance.fetchExams();
        final forced = ExamService.instance.fetchExams(forceRefresh: true);
        await waitFor(() => calls == 2);
        expect(calls, 2);

        slow.complete(
          jsonBody({
            'items': [sampleItems[0]],
          }),
        );
        expect((await nonForce).single.courseName, '高等数学');

        fast.complete(
          jsonBody({
            'items': [sampleItems[1]],
          }),
        );
        expect((await forced).single.courseName, '大学物理');
        expect(ExamService.instance.cachedExams!.single.courseName, '大学物理');
      },
    );
  });

  group('ExamService automatic login pause', () {
    test(
      'manualRequired propagates automaticLoginPaused to the expired exception',
      () async {
        await loginAcademic('A');
        // 会话恢复一律失败，确保 guard 走到自动登录分支并判定 manualRequired。
        ConnectModeResolver.instance.directReachabilityChecker = () async =>
            false;
        ConnectModeResolver.instance.webVpnReachabilityChecker = () async =>
            false;
        AcademicAuthGuard.debugAutomaticLoginOverride =
            (domain, {String? expectedAccount}) async {
              expect(domain, AuthRecoveryDomain.academic);
              return AutomaticLoginOutcome.manualRequired;
            };
        addTearDown(() {
          AcademicAuthGuard.debugAutomaticLoginOverride = null;
          ConnectModeResolver.instance.debugReset();
        });

        final adapter = MockHttpClientAdapter()
          ..registerText('GET', termEndpoint, '<html></html>')
          ..register(
            'POST',
            examEndpoint,
            (_) async => ResponseBody.fromString(
              '',
              302,
              headers: <String, List<String>>{
                'location': <String>['/jwglxt/xtgl/login_slogin.html'],
              },
            ),
          );
        DioClient.instance.dio.httpClientAdapter = adapter;

        await expectLater(
          ExamService.instance.fetchExams(forceRefresh: true),
          throwsA(
            isA<ExamAuthExpiredException>().having(
              (e) => e.automaticLoginPaused,
              'automaticLoginPaused',
              isTrue,
            ),
          ),
        );
      },
    );
  });
}
