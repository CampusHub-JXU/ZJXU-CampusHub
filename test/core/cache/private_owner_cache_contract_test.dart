import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/semester/current_term_resolver.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';

import '../../helpers/credential_store_test_ext.dart';
import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

/// 成绩 / 考试私有缓存的**共享契约**：两个功能使用同一套「固定 storage key +
/// owner/epoch 元数据 + 15 分钟 TTL + sessionRevision 守卫」语义，本套件对二者
/// 跑完全相同的断言。功能专属行为（排序、nextExam、请求体、异常类型）留在各自
/// 的 service 测试里。
abstract class OwnerCacheHarness {
  String get name;
  String get cacheKey;
  String get legacyPrefix;
  Duration get refreshWindow;

  Matcher get requestException;
  Matcher get authExpiredException;

  /// 单条记录的 JSON 载荷（服务端 `items` 元素 / 磁盘 `payload` 元素）。
  Map<String, Object?> item(String label);

  Future<void> setUpEnvironment();

  /// 安装 mock adapter；[respond] 以 1 起的调用序号返回响应。
  MockHttpClientAdapter installAdapter([
    Future<ResponseBody> Function(int call)? respond,
  ]);

  String get requestPath;

  Future<void> restoreBarrier(Future<void> Function()? barrier);
  void reset();
  Future<bool> restore();

  /// 以当前登录账号 [owner] 发起 fetch，返回结果的 label 列表。
  Future<List<String>> fetch(String owner, {bool force = false});

  /// 对「仅服务端 fetch 要求显式账号」的功能（成绩）与「可省略账号」的功能（考试）
  /// 都调用 fetch 的默认账号形式。
  List<String>? get cachedLabels;
  DateTime? get updatedAt;
  bool get isFresh;
  bool get isStale;
}

ResponseBody jsonBody(Object? data) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: <String, List<String>>{
    Headers.contentTypeHeader: <String>['application/json'],
  },
);

class GradesHarness extends OwnerCacheHarness {
  @override
  String get name => 'grades';
  @override
  String get cacheKey => GradesService.cacheKey;
  @override
  String get legacyPrefix => 'grades_cached_';
  @override
  Duration get refreshWindow => GradesService.refreshWindow;
  @override
  Matcher get requestException => throwsA(isA<GradesRequestException>());
  @override
  Matcher get authExpiredException =>
      throwsA(isA<GradesAuthExpiredException>());
  @override
  String get requestPath => '/jwglxt/cjcx/cjcx_cxDgXscj.html';

  @override
  Map<String, Object?> item(String label) => {
    'kcmc': label,
    'cj': '良好',
    'bfzcj': '86',
    'jd': '3.8',
    'xf': '2.0',
  };

  @override
  Future<void> setUpEnvironment() async {}

  @override
  MockHttpClientAdapter installAdapter([
    Future<ResponseBody> Function(int call)? respond,
  ]) {
    var calls = 0;
    final adapter = MockHttpClientAdapter();
    adapter.register('POST', requestPath, (options) {
      calls += 1;
      return respond != null
          ? respond(calls)
          : Future.value(
              jsonBody({
                'items': [item('default')],
              }),
            );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;
    return adapter;
  }

  @override
  Future<void> restoreBarrier(Future<void> Function()? barrier) async {
    GradesService.instance.debugRestoreBarrier = barrier;
  }

  @override
  void reset() => GradesService.instance.debugReset();

  @override
  Future<bool> restore() => GradesService.instance.restoreCache();

  @override
  Future<List<String>> fetch(String owner, {bool force = false}) async =>
      (await GradesService.instance.fetchGrades(
        owner,
        forceRefresh: force,
      )).map((e) => e.courseName).toList();

  @override
  List<String>? get cachedLabels =>
      GradesService.instance.cachedGrades?.map((e) => e.courseName).toList();
  @override
  DateTime? get updatedAt => GradesService.instance.updatedAt;
  @override
  bool get isFresh => GradesService.instance.isCacheFresh;
  @override
  bool get isStale => GradesService.instance.isStale;
}

class ExamHarness extends OwnerCacheHarness {
  static const _termPath = '/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html';
  static final String _date = () {
    final d = DateTime.now().add(const Duration(days: 14));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }();

  @override
  String get name => 'exam';
  @override
  String get cacheKey => ExamService.cacheKey;
  @override
  String get legacyPrefix => 'exam_cached_';
  @override
  Duration get refreshWindow => ExamService.refreshWindow;
  @override
  Matcher get requestException => throwsA(isA<ExamRequestException>());
  @override
  Matcher get authExpiredException => throwsA(isA<ExamAuthExpiredException>());
  @override
  String get requestPath => '/jwglxt/kwgl/kscx_cxXsksxxIndex.html';

  @override
  Map<String, Object?> item(String label) => {
    'kcmc': label,
    'kch': 'C-$label',
    'kssj': '第5周 周三($_date) 14:00-16:00',
    'cdmc': '教学楼A301',
    'cdxqmc': '本部',
    'zwh': '15',
    'ksmc': '期末考试',
    'kkxy': '理学院',
    'cxbj': '',
    'xnmc': '2025-2026',
    'xqmmc': '第二学期',
  };

  @override
  Future<void> setUpEnvironment() => CurrentTermResolver.instance.debugReset();

  @override
  MockHttpClientAdapter installAdapter([
    Future<ResponseBody> Function(int call)? respond,
  ]) {
    var calls = 0;
    final adapter = MockHttpClientAdapter()
      ..registerText('GET', _termPath, '<html></html>');
    adapter.register('POST', requestPath, (options) {
      calls += 1;
      return respond != null
          ? respond(calls)
          : Future.value(
              jsonBody({
                'items': [item('default')],
              }),
            );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;
    return adapter;
  }

  @override
  Future<void> restoreBarrier(Future<void> Function()? barrier) async {
    ExamService.instance.debugRestoreBarrier = barrier;
  }

  @override
  void reset() => ExamService.instance.debugReset();

  @override
  Future<bool> restore() => ExamService.instance.restoreCache();

  @override
  Future<List<String>> fetch(String owner, {bool force = false}) async =>
      (await ExamService.instance.fetchExams(
        studentId: owner,
        forceRefresh: force,
      )).map((e) => e.courseName).toList();

  @override
  List<String>? get cachedLabels =>
      ExamService.instance.cachedExams?.map((e) => e.courseName).toList();
  @override
  DateTime? get updatedAt => ExamService.instance.updatedAt;
  @override
  bool get isFresh => ExamService.instance.isCacheFresh;
  @override
  bool get isStale => ExamService.instance.isStale;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final h in <OwnerCacheHarness>[GradesHarness(), ExamHarness()]) {
    group('private owner cache contract [${h.name}]', () {
      setUp(() async {
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
        ConnectModeResolver.instance.directReachabilityChecker = () async =>
            true;
        await h.setUpEnvironment();
        DioClient.instance.debugCookieDirectoryPathProvider = (
          folderName,
        ) async => 'test/$folderName';
        await DioClient.instance.ensureInitialized();
      });

      Future<int> loginAcademic(String account) async {
        ZhengfangAuth.instance.debugSetSession(
          active: true,
          studentId: account,
        );
        await CredentialStore.instance.saveZhengfangSession(account);
        return (await AuthSessionPersistence.instance.read(
          CredentialSessionDomain.academic,
        )).epoch;
      }

      Future<void> seed({
        required String owner,
        required int epoch,
        DateTime? savedAt,
        Object? payload,
      }) => SharedPreferencesPrivateCacheStore(h.cacheKey).write(
        PrivateCacheEnvelope(
          owner: owner,
          updatedAt: savedAt ?? DateTime.now(),
          epoch: epoch,
          payload: payload ?? [h.item('seeded')],
        ),
      );

      Future<void> seedRaw(String raw) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(h.cacheKey, raw);
      }

      Future<Object?> rawOnDisk() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        return prefs.getString(h.cacheKey);
      }

      Future<void> relogin(String account) async {
        await ZhengfangAuth.instance.markLoggedOut();
        ZhengfangAuth.instance.debugSetSession(
          active: true,
          studentId: account,
        );
        await ZhengfangAuth.instance.markLoggedIn();
      }

      test('storage key and TTL are the published constants', () {
        expect(h.cacheKey, '${h.name}_private_cache_v1');
        expect(h.refreshWindow, const Duration(minutes: 15));
      });

      // ---- owner 归属 ----
      group('owner', () {
        test('another account cache is never shown as current', () async {
          await loginAcademic('B');
          await seed(owner: 'A', epoch: 1);

          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
          expect(h.updatedAt, isNull);
        });

        test('no explicit identity: restore does not fall back', () async {
          await seed(owner: 'A', epoch: 1);

          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
        });

        test(
          'in-memory cache is hidden right after an account switch',
          () async {
            final epoch = await loginAcademic('A');
            await seed(owner: 'A', epoch: epoch);
            expect(await h.restore(), isTrue);
            expect(h.cachedLabels, ['seeded']);

            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: 'B',
            );

            expect(h.cachedLabels, isNull);
          },
        );

        test('fetch for a different account sends no request', () async {
          await loginAcademic('A');
          final adapter = h.installAdapter();

          await expectLater(h.fetch('B'), h.requestException);
          expect(adapter.requestLog, isEmpty);
          expect(h.cachedLabels, isNull);
        });

        test('fetch without a durable session fails closed', () async {
          ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
          final adapter = h.installAdapter();

          await expectLater(h.fetch('A'), h.authExpiredException);
          expect(adapter.requestLog, isEmpty);
        });
      });

      // ---- TTL ----
      group('ttl', () {
        test('fresh restored cache is served without network', () async {
          final epoch = await loginAcademic('A');
          await seed(owner: 'A', epoch: epoch);
          await h.restore();
          expect(h.isFresh, isTrue);
          expect(h.isStale, isFalse);

          final adapter = h.installAdapter();
          expect(await h.fetch('A'), ['seeded']);
          expect(adapter.requestLog, isEmpty);
        });

        test('expired cache is stale and triggers a refetch', () async {
          final epoch = await loginAcademic('A');
          await seed(
            owner: 'A',
            epoch: epoch,
            savedAt: DateTime.now().subtract(const Duration(minutes: 16)),
          );
          await h.restore();
          expect(h.isFresh, isFalse);
          expect(h.isStale, isTrue);
          // 过期缓存仍可展示（cache-first），只是需要刷新。
          expect(h.cachedLabels, ['seeded']);

          final adapter = h.installAdapter(
            (_) async => jsonBody({
              'items': [h.item('refetched')],
            }),
          );
          expect(await h.fetch('A'), ['refetched']);
          expect(adapter.requestLog, contains('POST ${h.requestPath}'));
        });

        test('just inside the window is fresh', () async {
          final epoch = await loginAcademic('A');
          await seed(
            owner: 'A',
            epoch: epoch,
            savedAt: DateTime.now().subtract(const Duration(minutes: 14)),
          );
          await h.restore();
          expect(h.isFresh, isTrue);
        });

        test('forceRefresh bypasses a fresh cache', () async {
          final epoch = await loginAcademic('A');
          await seed(owner: 'A', epoch: epoch);
          await h.restore();

          final adapter = h.installAdapter(
            (_) async => jsonBody({
              'items': [h.item('forced')],
            }),
          );
          expect(await h.fetch('A', force: true), ['forced']);
          expect(adapter.requestLog, contains('POST ${h.requestPath}'));
        });

        test(
          'successful fetch refreshes updatedAt and serves from memory',
          () async {
            await loginAcademic('A');
            final before = DateTime.now();
            h.installAdapter();
            await h.fetch('A', force: true);

            expect(h.cachedLabels, ['default']);
            expect(h.updatedAt!.isBefore(before), isFalse);
            expect(h.isFresh, isTrue);

            final adapter = h.installAdapter();
            await h.fetch('A');
            expect(adapter.requestLog, isEmpty);
          },
        );
      });

      // ---- 登出 / 换号 / 同账号重登：迟到结果与内存失效 ----
      group('identity changes', () {
        Future<(Future<List<String>>, Completer<ResponseBody>)> startForced(
          String owner,
        ) async {
          final response = Completer<ResponseBody>();
          final started = Completer<void>();
          h.installAdapter((_) {
            if (!started.isCompleted) started.complete();
            return response.future;
          });
          final future = h.fetch(owner, force: true);
          // 避免在 await 之前出现未处理异常。
          unawaited(future.then<void>((_) {}, onError: (Object _) {}));
          await started.future;
          return (future, response);
        }

        test('late result after account switch is dropped', () async {
          await loginAcademic('A');
          final (future, response) = await startForced('A');

          ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'B');
          response.complete(
            jsonBody({
              'items': [h.item('late')],
            }),
          );

          await expectLater(future, h.requestException);
          expect(h.cachedLabels, isNull);
          expect(await rawOnDisk(), isNull);
        });

        test('late result after logout is dropped', () async {
          await loginAcademic('A');
          await ZhengfangAuth.instance.markLoggedIn();
          final (future, response) = await startForced('A');

          await ZhengfangAuth.instance.markLoggedOut();
          response.complete(
            jsonBody({
              'items': [h.item('late')],
            }),
          );

          await expectLater(future, throwsA(isA<Object>()));
          expect(h.cachedLabels, isNull);
          expect(await rawOnDisk(), isNull);
        });

        test('late result after same-account re-login is dropped', () async {
          await loginAcademic('A');
          await ZhengfangAuth.instance.markLoggedIn();
          final (future, response) = await startForced('A');

          await relogin('A');
          response.complete(
            jsonBody({
              'items': [h.item('late')],
            }),
          );

          await expectLater(future, h.requestException);
          expect(h.cachedLabels, isNull);
          expect(await rawOnDisk(), isNull);
        });

        test(
          'same-account re-login hides the in-memory cache at once',
          () async {
            final epoch = await loginAcademic('A');
            await seed(owner: 'A', epoch: epoch);
            await h.restore();
            expect(h.cachedLabels, isNotNull);

            await relogin('A');

            expect(h.cachedLabels, isNull);
            expect(h.updatedAt, isNull);
          },
        );

        test(
          'durable re-login without notify: next durable read drops memory',
          () async {
            final epoch = await loginAcademic('A');
            await seed(owner: 'A', epoch: epoch);
            await h.restore();
            expect(h.cachedLabels, isNotNull);

            await CredentialStore.instance.saveZhengfangSession('A');

            expect(await h.restore(), isFalse);
            expect(h.cachedLabels, isNull);
          },
        );

        test('old-epoch record is not adopted after re-login', () async {
          final epoch = await loginAcademic('A');
          await seed(owner: 'A', epoch: epoch);
          await CredentialStore.instance.saveZhengfangSession('A');
          h.reset();

          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
        });

        test('restore racing a same-account re-login adopts nothing', () async {
          final epoch = await loginAcademic('A');
          await seed(owner: 'A', epoch: epoch);
          await h.restoreBarrier(() async {
            await ZhengfangAuth.instance.markLoggedOut();
            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: 'A',
            );
            await ZhengfangAuth.instance.markLoggedIn();
          });

          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
          expect(h.updatedAt, isNull);
        });

        test('concurrent identical fetches share one request', () async {
          await loginAcademic('A');
          final response = Completer<ResponseBody>();
          var calls = 0;
          h.installAdapter((_) {
            calls += 1;
            return response.future;
          });

          final first = h.fetch('A', force: true);
          final second = h.fetch('A', force: true);
          for (var i = 0; i < 200 && calls == 0; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          response.complete(
            jsonBody({
              'items': [h.item('one')],
            }),
          );

          expect(await first, ['one']);
          expect(await second, ['one']);
          expect(calls, 1);
        });

        test('non-force joins an in-flight force request', () async {
          await loginAcademic('A');
          final response = Completer<ResponseBody>();
          var calls = 0;
          h.installAdapter((_) {
            calls += 1;
            return response.future;
          });

          final forced = h.fetch('A', force: true);
          final plain = h.fetch('A');
          for (var i = 0; i < 200 && calls == 0; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          response.complete(
            jsonBody({
              'items': [h.item('one')],
            }),
          );

          expect(await forced, ['one']);
          expect(await plain, ['one']);
          expect(calls, 1);
        });

        test('newer force request wins over an older non-force one', () async {
          await loginAcademic('A');
          final slow = Completer<ResponseBody>();
          final fast = Completer<ResponseBody>();
          var calls = 0;
          h.installAdapter((call) {
            calls = call;
            return call == 1 ? slow.future : fast.future;
          });

          final plain = h.fetch('A');
          final forced = h.fetch('A', force: true);
          for (var i = 0; i < 200 && calls < 2; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(calls, 2);

          slow.complete(
            jsonBody({
              'items': [h.item('OLD')],
            }),
          );
          expect(await plain, ['OLD']);
          fast.complete(
            jsonBody({
              'items': [h.item('NEW')],
            }),
          );
          expect(await forced, ['NEW']);
          expect(h.cachedLabels, ['NEW']);
        });
      });

      // ---- 磁盘数据损坏：fail closed ----
      group('corrupt disk data', () {
        late int epoch;

        setUp(() async {
          epoch = await loginAcademic('A');
        });

        Map<String, Object?> envelope({
          Object? v = 2,
          Object? owner = 'A',
          Object? updatedAt,
          Object? epochValue,
          Object? payload,
        }) => {
          'v': v,
          'owner': owner,
          'updatedAt': updatedAt ?? DateTime.now().toIso8601String(),
          'epoch': epochValue ?? epoch,
          'payload': payload ?? [h.item('seeded')],
        };

        final cases = <String, Object? Function(int)>{
          'not json': (_) => '{{{ nope',
          'json but not an object': (_) => '[1,2,3]',
          'empty string': (_) => '',
          'old schema v1': (_) => jsonEncode({
            'v': 1,
            'owner': 'A',
            'updatedAt': DateTime.now().toIso8601String(),
            'payload': [],
          }),
        };

        for (final entry in cases.entries) {
          test('${entry.key} -> no cache', () async {
            await seedRaw(entry.value(epoch) as String);
            expect(await h.restore(), isFalse);
            expect(h.cachedLabels, isNull);
            expect(h.updatedAt, isNull);
          });
        }

        test('missing epoch -> no cache', () async {
          final map = envelope()..remove('epoch');
          await seedRaw(jsonEncode(map));
          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
        });

        test('blank owner -> no cache', () async {
          await seedRaw(jsonEncode(envelope(owner: '  ')));
          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
        });

        test('bad timestamp -> no cache', () async {
          await seedRaw(jsonEncode(envelope(updatedAt: 'yesterday-ish')));
          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
        });

        test('payload of the wrong shape -> no cache', () async {
          await seedRaw(jsonEncode(envelope(payload: 'oops')));
          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);

          await seedRaw(jsonEncode(envelope(payload: [1, 2, 3])));
          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
        });

        test('corrupt disk record does not block a later good fetch', () async {
          await seedRaw('garbage');
          h.installAdapter(
            (_) async => jsonBody({
              'items': [h.item('good')],
            }),
          );
          expect(await h.fetch('A', force: true), ['good']);
          expect(h.cachedLabels, ['good']);
          expect(await h.restore(), isTrue);
        });
      });

      // ---- 持久化受身份证明约束 ----
      group('persist gated on identity proof', () {
        test(
          'durable revoke while in flight: result discarded, nothing written',
          () async {
            await loginAcademic('A');
            final response = Completer<ResponseBody>();
            final started = Completer<void>();
            h.installAdapter((_) {
              if (!started.isCompleted) started.complete();
              return response.future;
            });
            final future = h.fetch('A', force: true);
            unawaited(future.then<void>((_) {}, onError: (Object _) {}));
            await started.future;

            await AuthSessionPersistence.instance.revoke(
              CredentialSessionDomain.academic,
            );
            response.complete(
              jsonBody({
                'items': [h.item('late')],
              }),
            );

            await expectLater(future, h.authExpiredException);
            expect(await rawOnDisk(), isNull);
            expect(h.cachedLabels, isNull);
          },
        );

        test(
          'same-account durable re-login while in flight: nothing written',
          () async {
            await loginAcademic('A');
            final response = Completer<ResponseBody>();
            final started = Completer<void>();
            h.installAdapter((_) {
              if (!started.isCompleted) started.complete();
              return response.future;
            });
            final future = h.fetch('A', force: true);
            unawaited(future.then<void>((_) {}, onError: (Object _) {}));
            await started.future;

            await CredentialStore.instance.saveZhengfangSession('A');
            response.complete(
              jsonBody({
                'items': [h.item('late')],
              }),
            );

            await expectLater(future, h.authExpiredException);
            expect(await rawOnDisk(), isNull);
          },
        );

        test(
          'committed record carries the durable epoch of its identity',
          () async {
            final epoch = await loginAcademic('A');
            h.installAdapter();
            await h.fetch('A', force: true);

            final record = await SharedPreferencesPrivateCacheStore(h.cacheKey)
                .read();
            expect(record, isNotNull);
            expect(record!.owner, 'A');
            expect(record.epoch, epoch);

            // 写完成后同账号重登：旧记录属于旧纪元，不再被采纳。
            await CredentialStore.instance.saveZhengfangSession('A');
            h.reset();
            expect(await h.restore(), isFalse);
            expect(h.cachedLabels, isNull);
          },
        );
      });

      // ---- 磁盘格式兼容（现有用户缓存必须仍可读） ----
      group('on-disk format compatibility', () {
        test(
          'v2 envelope written by the previous implementation loads',
          () async {
            final epoch = await loginAcademic('A');
            final savedAt = DateTime.now().subtract(const Duration(minutes: 3));
            // 字面 fixture：按旧实现的 envelope 形状手写，不经过任何新代码。
            await seedRaw(
              jsonEncode({
                'v': 2,
                'owner': 'A',
                'updatedAt': savedAt.toIso8601String(),
                'epoch': epoch,
                'payload': [h.item('fixture')],
              }),
            );

            expect(await h.restore(), isTrue);
            expect(h.cachedLabels, ['fixture']);
            expect(h.updatedAt!.toIso8601String(), savedAt.toIso8601String());
            expect(h.isFresh, isTrue);
          },
        );

        test('a fetch persists the exact envelope shape', () async {
          final epoch = await loginAcademic('A');
          h.installAdapter();
          await h.fetch('A', force: true);

          final decoded = jsonDecode(
            (await rawOnDisk())! as String,
          ) as Map<String, dynamic>;
          expect(decoded.keys.toSet(), {
            'v',
            'owner',
            'updatedAt',
            'epoch',
            'payload',
          });
          expect(decoded['v'], 2);
          expect(decoded['owner'], 'A');
          expect(decoded['epoch'], epoch);
          expect(DateTime.tryParse(decoded['updatedAt'] as String), isNotNull);
          final payload = decoded['payload'] as List<dynamic>;
          expect(payload, hasLength(1));
          expect((payload.single as Map<String, dynamic>)['kcmc'], 'default');
        });

        test('legacy multi-key cache is discarded, not migrated', () async {
          await loginAcademic('A');
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            '${h.legacyPrefix}data',
            jsonEncode([h.item('legacy')]),
          );
          await prefs.setInt(
            '${h.legacyPrefix}at',
            DateTime.now().millisecondsSinceEpoch,
          );
          await prefs.setString('${h.legacyPrefix}owner', 'A');

          expect(await h.restore(), isFalse);
          expect(h.cachedLabels, isNull);
          expect(prefs.getString('${h.legacyPrefix}data'), isNull);
          expect(prefs.getInt('${h.legacyPrefix}at'), isNull);
          expect(prefs.getString('${h.legacyPrefix}owner'), isNull);
          expect(await rawOnDisk(), isNull);
        });
      });
    });
  }
}
