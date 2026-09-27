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
import 'package:jxu_campus_hub/features/grades/grades_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

Map<String, Object?> gradeItem({String name = '大学英语', String gpa = '3.8'}) => {
  'kcmc': name,
  'cj': '良好',
  'bfzcj': '86',
  'jd': gpa,
  'xf': '2.0',
};

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const endpoint = '/jwglxt/cjcx/cjcx_cxDgXscj.html';

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
    final store = SharedPreferencesPrivateCacheStore(GradesService.cacheKey);
    await store.write(
      PrivateCacheEnvelope(
        owner: owner,
        updatedAt: savedAt,
        epoch: epoch,
        payload: items ?? [gradeItem()],
      ),
    );
  }

  Future<void> seedLegacy({
    required DateTime savedAt,
    String? owner,
    Object? items,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'grades_cached_data',
      jsonEncode(items ?? [gradeItem()]),
    );
    await prefs.setInt('grades_cached_at', savedAt.millisecondsSinceEpoch);
    if (owner != null) await prefs.setString('grades_cached_owner', owner);
  }

  group('fetchGrades request', () {
    test('posts expected payload and maps items', () async {
      await loginAcademic('20250001');
      final adapter = MockHttpClientAdapter();
      adapter.register('POST', endpoint, (options) async {
        expect(options.queryParameters['doType'], 'query');
        expect(options.queryParameters['gnmkdm'], 'N305005');
        expect(options.queryParameters['su'], '20250001');
        expect(options.data, contains('queryModel.showCount=100'));
        expect(options.data, contains('queryModel.currentPage=1'));
        return jsonBody({
          'items': [gradeItem()],
        });
      });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await GradesService.instance.fetchGrades('20250001');

      expect(adapter.requestLog, ['POST $endpoint']);
      expect(result, hasLength(1));
      expect(result.single.courseName, '大学英语');
      expect(result.single.gpaPoints, 3.8);
    });

    test(
      'unrecognized grades response cannot overwrite the last successful data',
      () async {
        await loginAcademic('20250001');
        final adapter = MockHttpClientAdapter()
          ..registerJson('POST', endpoint, {'rows': []});
        DioClient.instance.dio.httpClientAdapter = adapter;

        await expectLater(
          GradesService.instance.fetchGrades('20250001'),
          throwsA(isA<GradesRequestException>()),
        );
        expect(GradesService.instance.cachedGrades, isNull);
      },
    );

    test(
      'webvpn mode uses the authenticated cookie client and proxy URL',
      () async {
        await loginAcademic('20250001');
        ZhengfangAuth.instance.setMode(ZhengfangMode.webVpn);
        final endpointPath = Uri.parse(
          ZhengfangAuth.instance.buildPortalUrl('/cjcx/cjcx_cxDgXscj.html'),
        ).path;
        final adapter = MockHttpClientAdapter();
        adapter.registerJson('POST', endpointPath, {'items': []});
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        final result = await GradesService.instance.fetchGrades(
          '20250001',
          forceRefresh: true,
        );

        expect(result, isEmpty);
        expect(adapter.requestLog, ['POST $endpointPath']);
      },
    );
  });

  group('fetchGrades identity gate', () {
    test('not logged in sends no request', () async {
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        GradesService.instance.fetchGrades('20250001'),
        throwsA(isA<GradesAuthExpiredException>()),
      );
      expect(adapter.requestLog, isEmpty);
      expect(GradesService.instance.cachedGrades, isNull);
    });

    test('logged in as A but passing B sends no request', () async {
      await loginAcademic('A');
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        GradesService.instance.fetchGrades('B'),
        throwsA(isA<GradesRequestException>()),
      );
      expect(adapter.requestLog, isEmpty);
      expect(GradesService.instance.cachedGrades, isNull);
    });

    test('blank student id sends no request', () async {
      await loginAcademic('A');
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        GradesService.instance.fetchGrades('   '),
        throwsA(isA<GradesRequestException>()),
      );
      expect(adapter.requestLog, isEmpty);
    });

    test('in-memory identity without durable session fails closed', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        GradesService.instance.fetchGrades('A'),
        throwsA(isA<GradesAuthExpiredException>()),
      );
      expect(adapter.requestLog, isEmpty);
    });
  });

  group('grades cache ownership, epoch and TTL', () {
    test(
      'restore reads only the current durable epoch + owner cache',
      () async {
        final epoch = await loginAcademic('A');
        await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());

        expect(await GradesService.instance.restoreCache(), isTrue);
        expect(GradesService.instance.cachedGrades, hasLength(1));
      },
    );

    test('restore without an explicit identity does not fall back', () async {
      await seedEnvelope(owner: 'A', epoch: 1, savedAt: DateTime.now());

      expect(await GradesService.instance.restoreCache(), isFalse);
      expect(GradesService.instance.cachedGrades, isNull);
    });

    test('restore with an old durable epoch is not shown', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      expect(await GradesService.instance.restoreCache(), isTrue);

      // 同账号重登推进持久 epoch，旧记录不再属于当前身份纪元。
      await CredentialStore.instance.saveZhengfangSession('A');
      GradesService.instance.debugReset();

      expect(await GradesService.instance.restoreCache(), isFalse);
      expect(GradesService.instance.cachedGrades, isNull);
    });

    test('restore completing after same-account re-login does not adopt old record', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());

      // 锁前推进 epoch：读取到旧 epoch 后同账号登出再登录（E -> E+2）。
      GradesService.instance.debugRestoreBarrier = () async {
        await ZhengfangAuth.instance.markLoggedOut();
        ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
        await ZhengfangAuth.instance.markLoggedIn();
      };

      expect(await GradesService.instance.restoreCache(), isFalse);
      expect(GradesService.instance.cachedGrades, isNull);
      expect(GradesService.instance.updatedAt, isNull);
    });

    test(
      'getter returns null after same-account re-login without new fetch',
      () async {
        final epoch = await loginAcademic('A');
        await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
        await GradesService.instance.restoreCache();
        expect(GradesService.instance.cachedGrades, isNotNull);

        // 同账号登出再登录：监听同步失效内存，getter 不暴露旧 epoch 记录。
        await ZhengfangAuth.instance.markLoggedOut();
        ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
        await ZhengfangAuth.instance.markLoggedIn();

        expect(GradesService.instance.cachedGrades, isNull);
        expect(GradesService.instance.updatedAt, isNull);
      },
    );

    test(
      'stale in-memory record is dropped once a new durable epoch is observed',
      () async {
        final epoch = await loginAcademic('A');
        await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
        await GradesService.instance.restoreCache();
        expect(GradesService.instance.cachedGrades, isNotNull);

        // 同账号重登推进 epoch 但无 notify；下一次 durable 读取必须失效旧记录。
        await CredentialStore.instance.saveZhengfangSession('A');
        expect(await GradesService.instance.restoreCache(), isFalse);
        expect(GradesService.instance.cachedGrades, isNull);
      },
    );

    test('legacy multi-key cache is discarded, not migrated', () async {
      await loginAcademic('A');
      await seedLegacy(savedAt: DateTime.now(), owner: 'A');

      expect(await GradesService.instance.restoreCache(), isFalse);
      expect(GradesService.instance.cachedGrades, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('grades_cached_data'), isNull);
      expect(prefs.getInt('grades_cached_at'), isNull);
      expect(prefs.getString('grades_cached_owner'), isNull);
      final store = SharedPreferencesPrivateCacheStore(GradesService.cacheKey);
      expect(await store.read(), isNull);
    });

    test('another account cache is never shown as current', () async {
      await loginAcademic('B');
      await seedEnvelope(owner: 'A', epoch: 1, savedAt: DateTime.now());

      expect(await GradesService.instance.restoreCache(), isFalse);
      expect(GradesService.instance.cachedGrades, isNull);
    });

    test(
      'switching account hides the previous account in-memory cache',
      () async {
        final epoch = await loginAcademic('A');
        await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
        await GradesService.instance.restoreCache();
        expect(GradesService.instance.cachedGrades, isNotNull);

        ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'B');

        expect(GradesService.instance.cachedGrades, isNull);
      },
    );

    test('fresh cache is served without touching the network', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      await GradesService.instance.restoreCache();

      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await GradesService.instance.fetchGrades('A');

      expect(result, hasLength(1));
      expect(adapter.requestLog, isEmpty);
    });

    test('expired cache triggers a refetch', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now().subtract(const Duration(minutes: 16)),
      );
      await GradesService.instance.restoreCache();
      expect(GradesService.instance.isCacheFresh, isFalse);
      expect(GradesService.instance.isStale, isTrue);

      final adapter = MockHttpClientAdapter()
        ..registerJson('POST', endpoint, {
          'items': [gradeItem(name: '数据结构')],
        });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await GradesService.instance.fetchGrades('A');

      expect(adapter.requestLog, ['POST $endpoint']);
      expect(result.single.courseName, '数据结构');
    });

    test('forceRefresh bypasses a fresh cache', () async {
      final epoch = await loginAcademic('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      await GradesService.instance.restoreCache();

      final adapter = MockHttpClientAdapter()
        ..registerJson('POST', endpoint, {
          'items': [gradeItem(name: '高等数学')],
        });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await GradesService.instance.fetchGrades(
        'A',
        forceRefresh: true,
      );

      expect(adapter.requestLog, ['POST $endpoint']);
      expect(result.single.courseName, '高等数学');
    });

    test('late result is dropped after same-account re-login', () async {
      await loginAcademic('A');
      await ZhengfangAuth.instance.markLoggedIn();

      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = MockHttpClientAdapter();
      adapter.register('POST', endpoint, (options) {
        if (!started.isCompleted) started.complete();
        return response.future;
      });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final future = GradesService.instance.fetchGrades(
        'A',
        forceRefresh: true,
      );
      await started.future;

      await ZhengfangAuth.instance.markLoggedOut();
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      await ZhengfangAuth.instance.markLoggedIn();

      response.complete(
        jsonBody({
          'items': [gradeItem()],
        }),
      );

      await expectLater(future, throwsA(isA<GradesRequestException>()));
      expect(GradesService.instance.cachedGrades, isNull);
    });

    test('durable revoke during in-flight request discards result', () async {
      await loginAcademic('A');

      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = MockHttpClientAdapter();
      adapter.register('POST', endpoint, (options) {
        if (!started.isCompleted) started.complete();
        return response.future;
      });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final future = GradesService.instance.fetchGrades(
        'A',
        forceRefresh: true,
      );
      await started.future;

      // 跨实例：持久撤销推进 epoch，本 isolate 内存身份未变。
      await AuthSessionPersistence.instance.revoke(
        CredentialSessionDomain.academic,
      );

      response.complete(
        jsonBody({
          'items': [gradeItem()],
        }),
      );

      await expectLater(future, throwsA(isA<GradesAuthExpiredException>()));
      final store = SharedPreferencesPrivateCacheStore(GradesService.cacheKey);
      expect(await store.read(), isNull);
    });

    test(
      'same-account durable re-login during request discards result',
      () async {
        await loginAcademic('A');

        final response = Completer<ResponseBody>();
        final started = Completer<void>();
        final adapter = MockHttpClientAdapter();
        adapter.register('POST', endpoint, (options) {
          if (!started.isCompleted) started.complete();
          return response.future;
        });
        DioClient.instance.dio.httpClientAdapter = adapter;

        final future = GradesService.instance.fetchGrades(
          'A',
          forceRefresh: true,
        );
        await started.future;

        // 同账号重登：持久 epoch 推进。
        await CredentialStore.instance.saveZhengfangSession('A');

        response.complete(
          jsonBody({
            'items': [gradeItem()],
          }),
        );

        await expectLater(future, throwsA(isA<GradesAuthExpiredException>()));
        final store = SharedPreferencesPrivateCacheStore(
          GradesService.cacheKey,
        );
        expect(await store.read(), isNull);
      },
    );

    test(
      'locked write then re-login: new epoch does not read old record',
      () async {
        final epoch = await loginAcademic('A');

        final adapter = MockHttpClientAdapter()
          ..registerJson('POST', endpoint, {
            'items': [gradeItem()],
          });
        DioClient.instance.dio.httpClientAdapter = adapter;
        await GradesService.instance.fetchGrades('A', forceRefresh: true);

        final store = SharedPreferencesPrivateCacheStore(
          GradesService.cacheKey,
        );
        final record = await store.read();
        expect(record, isNotNull);
        expect(record!.epoch, epoch);

        // 写完成后同账号重登推进 epoch：旧记录不再被读取。
        await CredentialStore.instance.saveZhengfangSession('A');
        GradesService.instance.debugReset();

        expect(await GradesService.instance.restoreCache(), isFalse);
      },
    );

    test(
      'cross-instance revoke during in-flight request is lock-serialized',
      () async {
        await loginAcademic('A');

        // 真实文件锁：服务用单例，另一实例共享同一锁目录，模拟跨 isolate/进程。
        final dir = await Directory.systemTemp.createTemp('grades_cache_lock_');
        addTearDown(() => dir.delete(recursive: true));
        AuthSessionPersistence.instance
          ..debugForceFileLock = true
          ..debugDirectoryProvider = () async => dir;
        final otherInstance = AuthSessionPersistence.debugNew(
          backend: _CredentialStoreEnvelopeBackend(),
          directoryProvider: () async => dir,
        )..debugForceFileLock = true;

        final response = Completer<ResponseBody>();
        final started = Completer<void>();
        final adapter = MockHttpClientAdapter();
        adapter.register('POST', endpoint, (options) {
          if (!started.isCompleted) started.complete();
          return response.future;
        });
        DioClient.instance.dio.httpClientAdapter = adapter;

        final future = GradesService.instance.fetchGrades(
          'A',
          forceRefresh: true,
        );
        await started.future;

        // 另一实例在服务落盘前撤销：锁内 epoch 校验拒绝旧写入。
        await otherInstance.revoke(CredentialSessionDomain.academic);

        response.complete(
          jsonBody({
            'items': [gradeItem()],
          }),
        );

        await expectLater(future, throwsA(isA<GradesAuthExpiredException>()));
        final store = SharedPreferencesPrivateCacheStore(
          GradesService.cacheKey,
        );
        expect(await store.read(), isNull);
      },
    );

    test('concurrent identical fetches share one request', () async {
      await loginAcademic('A');

      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      var calls = 0;
      final adapter = MockHttpClientAdapter();
      adapter.register('POST', endpoint, (options) {
        calls += 1;
        if (!started.isCompleted) started.complete();
        return response.future;
      });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final first = GradesService.instance.fetchGrades('A', forceRefresh: true);
      final second = GradesService.instance.fetchGrades(
        'A',
        forceRefresh: true,
      );
      await started.future;
      expect(calls, 1);

      response.complete(
        jsonBody({
          'items': [gradeItem()],
        }),
      );

      expect(await first, hasLength(1));
      expect(await second, hasLength(1));
      expect(calls, 1);
    });

    test('non-force shares an in-flight force request', () async {
      await loginAcademic('A');

      final response = Completer<ResponseBody>();
      var calls = 0;
      final adapter = MockHttpClientAdapter();
      adapter.register('POST', endpoint, (options) {
        calls += 1;
        return response.future;
      });
      DioClient.instance.dio.httpClientAdapter = adapter;

      final forced = GradesService.instance.fetchGrades(
        'A',
        forceRefresh: true,
      );
      final nonForce = GradesService.instance.fetchGrades('A');
      await waitFor(() => calls == 1);

      response.complete(
        jsonBody({
          'items': [gradeItem()],
        }),
      );

      expect(await forced, hasLength(1));
      expect(await nonForce, hasLength(1));
      expect(calls, 1);
    });

    test(
      'force starts a newer request; stale non-force cannot overwrite',
      () async {
        await loginAcademic('A');

        final slow = Completer<ResponseBody>();
        final fast = Completer<ResponseBody>();
        var calls = 0;
        final adapter = MockHttpClientAdapter();
        adapter.register('POST', endpoint, (options) {
          calls += 1;
          return calls == 1 ? slow.future : fast.future;
        });
        DioClient.instance.dio.httpClientAdapter = adapter;

        final nonForce = GradesService.instance.fetchGrades('A');
        final forced = GradesService.instance.fetchGrades(
          'A',
          forceRefresh: true,
        );
        await waitFor(() => calls == 2);
        expect(calls, 2);

        // 旧的非 force 结果先返回，不得覆盖后来的 force 数据。
        slow.complete(
          jsonBody({
            'items': [gradeItem(name: 'OLD')],
          }),
        );
        expect((await nonForce).single.courseName, 'OLD');

        fast.complete(
          jsonBody({
            'items': [gradeItem(name: 'NEW')],
          }),
        );
        expect((await forced).single.courseName, 'NEW');
        expect(GradesService.instance.cachedGrades!.single.courseName, 'NEW');
      },
    );
  });

  group('GradesService automatic login pause', () {
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

        final adapter = MockHttpClientAdapter();
        adapter.register(
          'POST',
          endpoint,
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
          GradesService.instance.fetchGrades('A', forceRefresh: true),
          throwsA(
            isA<GradesAuthExpiredException>().having(
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

/// 与生产相同的 CredentialStore 后端，供跨实例锁测试复用同一持久会话。
class _CredentialStoreEnvelopeBackend implements AuthSessionEnvelopeBackend {
  @override
  Future<CredentialSessionEnvelope> read(CredentialSessionDomain domain) =>
      CredentialStore.instance.readSessionEnvelope(domain);

  @override
  Future<void> write(
    CredentialSessionDomain domain,
    CredentialSessionEnvelope envelope,
  ) => CredentialStore.instance.writeSessionEnvelope(domain, envelope);
}
