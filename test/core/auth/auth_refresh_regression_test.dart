import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => Directory.systemTemp.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await resetTestEnvironment();
    await DioClient.instance.ensureInitialized();
    ConnectModeResolver.instance.directReachabilityChecker = () async => false;
    ConnectModeResolver.instance.webVpnReachabilityChecker = () async => false;
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'AUDIT_A');
    await CredentialStore.instance.saveZhengfangSession('AUDIT_A');
  });
  tearDown(() {
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
  });

  Future<AutomaticLoginAttemptResult> commitRecovery() async {
    final epoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.academic,
    );
    final receipt = await AuthSessionPersistence.instance.commit(
      CredentialSessionDomain.academic,
      account: 'AUDIT_A',
      expectedEpoch: epoch,
    );
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: 'AUDIT_A',
      forceRevision: true,
    );
    return AutomaticLoginAttemptResult(
      outcome: AutomaticLoginOutcome.committed,
      receipt: receipt,
    );
  }

  test('concurrent academic expiry shares one recovery and each receipt-bound retry', () async {
    var recoveryCalls = 0;
    final entered = Completer<void>();
    final commitGate = Completer<void>();
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
        (domain, {expectedAccount}) async {
          recoveryCalls++;
          entered.complete();
          await commitGate.future;
          return commitRecovery();
        };
    Future<AcademicGuardedResponse<dynamic>> query() {
      var requests = 0;
      return AcademicAuthGuard.guardWithSession<dynamic>(
        request: () async {
          requests++;
          return Response<dynamic>(
            requestOptions: RequestOptions(path: '/read-only'),
            statusCode: requests == 1 ? 901 : 200,
          );
        },
      );
    }

    final first = query();
    final second = query();
    await entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(recoveryCalls, 1);
    commitGate.complete();
    final responses = await Future.wait([first, second]);
    for (final result in responses) {
      expect(result.response.statusCode, 200);
      expect(result.account, 'AUDIT_A');
      expect(result.revision, ZhengfangAuth.instance.sessionRevision);
      expect(
        result.epoch,
        await AuthSessionPersistence.instance.readEpoch(
          CredentialSessionDomain.academic,
        ),
      );
    }
    expect(recoveryCalls, 1);
  });

  test('grades recovery persists the successful retry and restores it on warm start', () async {
    var posts = 0;
    var recoveries = 0;
    final adapter = MockHttpClientAdapter();
    adapter.register('POST', '/jwglxt/cjcx/cjcx_cxDgXscj.html', (_) async {
      posts++;
      return ResponseBody.fromString(
        posts == 1 ? '{}' : '{"items":[{"kcmc":"Audit Course","cj":"90","jd":"4.0","xf":"2"}]}',
        posts == 1 ? 901 : 200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
        (domain, {expectedAccount}) async {
          recoveries++;
          return commitRecovery();
        };
    final grades = await GradesService.instance.fetchGrades(
      'AUDIT_A',
      forceRefresh: true,
    );
    expect(grades, hasLength(1));
    expect(posts, 2);
    expect(recoveries, 1);
    expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    expect(
      (await SharedPreferencesPrivateCacheStore(
        GradesService.cacheKey,
      ).read())?.owner,
      'AUDIT_A',
    );
    GradesService.instance.debugReset();
    expect(await GradesService.instance.restoreCache(), isTrue);
    expect(GradesService.instance.cachedGrades, isNotNull);
  });

  test(
    'exam recovery persists the successful retry and restores it on warm start',
    () async {
      var posts = 0;
      final adapter = MockHttpClientAdapter();
      adapter.register('POST', '/jwglxt/kwgl/kscx_cxXsksxxIndex.html', (
        _,
      ) async {
        posts++;
        return ResponseBody.fromString(
          '{"items":[]}',
          posts == 1 ? 901 : 200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      DioClient.instance.dio.httpClientAdapter = adapter;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride = (
        domain, {
        expectedAccount,
      }) => commitRecovery();
      expect(
        await ExamService.instance.fetchExams(forceRefresh: true),
        isEmpty,
      );
      expect(posts, 2);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(
        (await SharedPreferencesPrivateCacheStore(
          ExamService.cacheKey,
        ).read())?.owner,
        'AUDIT_A',
      );
      ExamService.instance.debugReset();
      expect(await ExamService.instance.restoreCache(), isTrue);
      expect(ExamService.instance.cachedExams, isNotNull);
    },
  );

  test('academic server 500 is unknown and preserves the identity', () async {
    final adapter = MockHttpClientAdapter()
      ..registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        'Server error',
        statusCode: 500,
      );
    DioClient.instance.dio.httpClientAdapter = adapter;
    expect(
      await ZhengfangAuth.instance.validateSession(revokeOnInvalid: false),
      isNull,
    );
  });

  test('busy recovery preserves both memory and durable identity', () async {
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
        (domain, {expectedAccount}) async => const AutomaticLoginAttemptResult(
          outcome: AutomaticLoginOutcome.busy,
        );
    await expectLater(
      AcademicAuthGuard.guardRequest<dynamic>(
        request: () async => Response<dynamic>(
          requestOptions: RequestOptions(path: '/audit'),
          statusCode: 901,
        ),
      ),
      throwsA(isA<AcademicAuthExpiredException>()),
    );
    expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    expect(
      (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.academic,
      )).active,
      isTrue,
    );
  });

  test(
    'CAS validation preserves the durable epoch without a login exchange',
    () async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'AUDIT_CAS',
      );
      await CredentialStore.instance.saveUnifiedAuthSession('AUDIT_CAS');
      final before = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      );
      final revision = UnifiedAuthService.instance.sessionRevision;
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          MockHttpClientAdapter()..registerText(
            'GET',
            '/cas/login',
            '<html>existing session resource</html>',
          );
      expect(
        await UnifiedAuthService.instance.validateSession(
          syncWebViewCookies: false,
        ),
        isTrue,
      );
      expect(
        await AuthSessionPersistence.instance.readEpoch(
          CredentialSessionDomain.unified,
        ),
        before,
      );
      expect(UnifiedAuthService.instance.sessionRevision, revision);
    },
  );

  test(
    'confirmed probe has one bounded retry; a second expiry terminates',
    () async {
      ConnectModeResolver.instance.directReachabilityChecker = () async => true;
      DioClient.instance.dio.httpClientAdapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          '/jwglxt/xtgl/index_initMenu.html',
          '<html>/xtgl/index_initMenu.html</html>',
        );
      var attempts = 0;
      var requests = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {expectedAccount}) async {
            attempts++;
            return commitRecovery();
          };
      await expectLater(
        AcademicAuthGuard.guardRequest<dynamic>(
          request: () async {
            requests++;
            return Response<dynamic>(
              requestOptions: RequestOptions(path: '/audit'),
              statusCode: 901,
            );
          },
        ),
        throwsA(isA<AcademicAuthExpiredException>()),
      );
      expect(requests, 2);
      expect(attempts, 0);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
    },
  );

  test(
    'CAS server 500 is unknown and preserves the durable identity',
    () async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'AUDIT_CAS',
      );
      await CredentialStore.instance.saveUnifiedAuthSession('AUDIT_CAS');
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          MockHttpClientAdapter()..registerText(
            'GET',
            '/cas/login',
            'Server error',
            statusCode: 500,
          );
      expect(
        await UnifiedAuthService.instance.validateSession(
          syncWebViewCookies: false,
        ),
        isNull,
      );
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(
        (await AuthSessionPersistence.instance.read(
          CredentialSessionDomain.unified,
        )).active,
        isTrue,
      );
    },
  );
}
