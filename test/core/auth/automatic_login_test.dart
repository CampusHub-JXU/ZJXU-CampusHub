import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/auth_failure.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/captcha/captcha_recognizer.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

import '../../helpers/mock_http_client_adapter.dart';

final Uint8List _png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
  4,
]);

/// 记录每次 OCR 的 `expectedLength`，可按需给出答案 / 阻塞。
class _FakeRecognizer implements CaptchaRecognizer {
  _FakeRecognizer({this.answer, this.gate});

  final String? answer;
  final Completer<void>? gate;
  final List<int> lengths = <int>[];
  final Completer<void> started = Completer<void>();

  @override
  Future<CaptchaRecognition?> recognize(
    Uint8List bytes, {
    required int expectedLength,
  }) async {
    lengths.add(expectedLength);
    if (!started.isCompleted) started.complete();
    final gated = gate;
    if (gated != null) await gated.future;
    final value = answer;
    return value == null ? null : CaptchaRecognition(text: value);
  }
}

/// CAS（统一认证）最小假传输：登录页 / 验证码 / 登录提交。
class _FakeCasAdapter extends MockHttpClientAdapter {
  _FakeCasAdapter() {    register('GET', '/cas/login', (options) async {
      return ResponseBody.fromString(
        '<html><form id="fm1" action="/cas/login">'
        '<input type="hidden" name="lt" value="LT-1" />'
        '<input type="hidden" name="execution" value="e1s1" />'
        '</form></html>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    });
    register('GET', '/cas/captcha.html', (options) async {
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['image/png'],
        },
      );
    });
    register('POST', '/cas/login', (options) async {
      loginPosts++;
      return ResponseBody.fromString(
        '<html>登录中</html>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    });
  }

  int loginPosts = 0;
}

/// 教务（正方）最小假传输：登录页 + 验证码（本测试只走到 OCR 前）。
class _FakeAcademicAdapter extends MockHttpClientAdapter {
  _FakeAcademicAdapter() {
    register('GET', '/jwglxt/xtgl/login_slogin.html', (options) async {
      return ResponseBody.fromString(
        '<html><input type="hidden" name="csrftoken" value="csrf-1" /></html>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    });
    register('GET', '/jwglxt/kaptcha', (options) async {
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['image/png'],
        },
      );
    });
  }
}

Response<Map<String, dynamic>> _okResponse() => Response<Map<String, dynamic>>(
  requestOptions: RequestOptions(path: '/x'),
  statusCode: 200,
  data: <String, dynamic>{'items': <dynamic>[]},
);

Response<Map<String, dynamic>> _redirectResponse() =>
    Response<Map<String, dynamic>>(
      requestOptions: RequestOptions(path: '/x'),
      statusCode: 302,
      data: null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory lockDir;
  late _FakeRecognizer recognizer;
  late AutomaticLoginService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    ConnectModeResolver.instance.debugReset();
    AuthSessionPersistence.instance.debugReset();
    AuthRecoveryStateStore.instance.debugReset();
    AuthOperationCoordinator.instance.debugReset();
    AcademicAuthGuard.debugAutomaticLoginOverride = null;
    // 恢复会话一律失败，确保 guard 走到自动登录分支。
    ConnectModeResolver.instance.directReachabilityChecker = () async => false;
    ConnectModeResolver.instance.webVpnReachabilityChecker = () async => false;

    lockDir = await Directory.systemTemp.createTemp('automatic_login_test_');
    AuthSessionPersistence.instance
      ..debugDisableFileLock = true
      ..debugDirectoryProvider = () async => lockDir;
    AuthRecoveryStateStore.instance.debugDirectoryProvider = () async =>
        lockDir;
    DioClient.instance.debugUseMemoryCookieStorage = true;
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        '${Directory.systemTemp.path}/jxuc_auto_login_test/$folderName/';
    await DioClient.instance.ensureInitialized();

    recognizer = _FakeRecognizer(answer: '1234');
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
  });

  tearDown(() async {
    AcademicAuthGuard.debugAutomaticLoginOverride = null;
    service.debugReset();
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    ConnectModeResolver.instance.debugReset();
    AuthSessionPersistence.instance.debugReset();
    AuthRecoveryStateStore.instance.debugReset();
    AuthOperationCoordinator.instance.debugReset();
    DioClient.instance.debugReset();
    NetworkSettings.instance.debugReset();
    if (await lockDir.exists()) await lockDir.delete(recursive: true);
  });

  Future<void> enableCasOptIn() => AuthRecoveryStateStore.instance.enable(
    AuthRecoveryDomain.cas,
    account: 'A',
    credentialRevision: 0,
  );

  Future<void> enableAcademicOptIn() => AuthRecoveryStateStore.instance.enable(
    AuthRecoveryDomain.academic,
    account: '2025000001',
    credentialRevision: 0,
  );

  test('CAS 成功提交一次、只 merge 一次且不同步 WebView Cookie', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();
    final epochBefore = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );

    final outcome = await service.attempt(AuthRecoveryDomain.cas);

    expect(outcome, AutomaticLoginOutcome.committed);
    expect(adapter.loginPosts, 1, reason: '真实 challenge 只提交一次');
    expect(recognizer.lengths, <int>[4], reason: 'CAS 固定 4 位，只识别一次');
    expect(
      UnifiedAuthService.instance.debugWebViewCookieSyncCalls,
      0,
      reason: '自动路径必须禁止 WebView cookie 同步',
    );

    final envelope = await CredentialStore.instance.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(envelope.active, isTrue);
    expect(envelope.account, 'A');
    expect(envelope.epoch, epochBefore + 1, reason: '唯一提交点只 merge/推进一次');
    expect(
      (await AuthRecoveryStateStore.instance.read(
        AuthRecoveryDomain.cas,
      )).activeAttempt,
      isNull,
    );
  });

  test('OCR 返回 null：按域固定长度只识别一次并瞬时退避，不涨身份失败', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    recognizer = _FakeRecognizer(answer: null);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();

    final outcome = await service.attempt(AuthRecoveryDomain.cas);

    expect(outcome, AutomaticLoginOutcome.failed);
    expect(recognizer.lengths, <int>[4], reason: '不做第二次长度尝试');
    expect(adapter.loginPosts, 0, reason: '未识别不得提交登录');
    final record = await AuthRecoveryStateStore.instance.read(
      AuthRecoveryDomain.cas,
    );
    expect(record.failureCount, 0, reason: 'OCR 认错 ≠ 身份错');
    expect(record.cooldownUntil, isNotNull, reason: '瞬时失败必须退避');
  });

  test('教务域使用固定 6 位且只识别一次', () async {
    DioClient.instance.dio.httpClientAdapter = _FakeAcademicAdapter();
    recognizer = _FakeRecognizer(answer: null);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveCredentials('2025000001', 'pw');
    await enableAcademicOptIn();

    final outcome = await service.attempt(AuthRecoveryDomain.academic);

    expect(outcome, AutomaticLoginOutcome.failed);
    expect(recognizer.lengths, <int>[6], reason: '教务固定 6 位，只识别一次');
    final record = await AuthRecoveryStateStore.instance.read(
      AuthRecoveryDomain.academic,
    );
    expect(record.failureCount, 0);
    expect(record.cooldownUntil, isNotNull);
  });

  test('凭据缺失直接 notEligible，不发起交换', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await enableCasOptIn();

    final outcome = await service.attempt(AuthRecoveryDomain.cas);

    expect(outcome, AutomaticLoginOutcome.notEligible);
    expect(recognizer.lengths, isEmpty);
    expect(adapter.loginPosts, 0);
  });

  test('身份失败累计到 3 后 manualRequired 且不再尝试交换', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();
    for (var i = 0; i < 3; i++) {
      await AuthOperationCoordinator.instance.recordIdentityFailure(
        AuthRecoveryDomain.cas,
        kind: AuthFailureKind.invalidCredentials,
      );
    }

    final outcome = await service.attempt(AuthRecoveryDomain.cas);

    expect(outcome, AutomaticLoginOutcome.manualRequired);
    expect(recognizer.lengths, isEmpty, reason: '暂停后不得再发起识别/交换');
    expect(adapter.loginPosts, 0);
  });

  test('同域并发第二次让位为 busy，只单飞一次交换', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    final gate = Completer<void>();
    recognizer = _FakeRecognizer(answer: '1234', gate: gate);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();

    final first = service.attempt(AuthRecoveryDomain.cas);
    await recognizer.started.future;

    final second = await service.attempt(AuthRecoveryDomain.cas);
    expect(second, AutomaticLoginOutcome.busy);
    expect(recognizer.lengths, <int>[4], reason: '第二次不得再发起识别');

    gate.complete();
    expect(await first, AutomaticLoginOutcome.committed);
    expect(adapter.loginPosts, 1);
  });

  group('AcademicAuthGuard 触发', () {
    test('自动登录提交成功后重试原请求一次', () async {
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            expect(domain, AuthRecoveryDomain.academic);
            return AutomaticLoginOutcome.committed;
          };
      var calls = 0;
      final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        request: () async {
          calls++;
          return calls == 1 ? _redirectResponse() : _okResponse();
        },
      );

      expect(resp.statusCode, 200);
      expect(calls, 2, reason: '自动登录成功后重试一次');
    });

    test('manualRequired 抛出可区分的过期异常且不重试', () async {
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async =>
              AutomaticLoginOutcome.manualRequired;
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          request: () async {
            calls++;
            return _redirectResponse();
          },
        ),
        throwsA(
          isA<AcademicAuthExpiredException>().having(
            (e) => e.automaticLoginPaused,
            'automaticLoginPaused',
            isTrue,
          ),
        ),
      );
      expect(calls, 1, reason: '暂停后不得重试');
    });

    test('自定义过期异常在 manualRequired 时走可区分类型', () async {
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async =>
              AutomaticLoginOutcome.manualRequired;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _MarkerException(),
          request: () async => _redirectResponse(),
        ),
        throwsA(isA<AcademicAuthManualLoginRequiredException>()),
      );
    });
  });
}

class _MarkerException implements Exception {
  const _MarkerException();
}
