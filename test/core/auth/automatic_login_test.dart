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
import 'package:jxu_campus_hub/core/auth/background_auth_context.dart';
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
  _FakeCasAdapter({List<String>? loginBodies})
    : _loginBodies = loginBodies ?? const <String>['<html>登录中</html>'] {
    register('GET', '/cas/login', (options) async {
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
      captchaGets++;
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['image/png'],
        },
      );
    });
    register('POST', '/cas/login', (options) async {
      final index = loginPosts < _loginBodies.length
          ? loginPosts
          : _loginBodies.length - 1;
      loginPosts++;
      return ResponseBody.fromString(
        _loginBodies[index],
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    });
  }

  final List<String> _loginBodies;
  int loginPosts = 0;
  int captchaGets = 0;
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
      headers: Headers.fromMap({
        'location': ['/jwglxt/xtgl/login_slogin.html'],
      }),
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
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
    // 恢复会话一律失败，确保 guard 走到自动登录分支。
    ConnectModeResolver.instance.directReachabilityChecker = () async => false;
    ConnectModeResolver.instance.webVpnReachabilityChecker = () async => false;
    ConnectModeResolver.instance.targetDirectReachabilityChecker = (_) async =>
        true;

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
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
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

  test('后台失去申领时两域均不发起交换', () async {
    final context = BackgroundAuthContext(mayContinue: () async => false);
    for (final domain in AuthRecoveryDomain.values) {
      final result = await context.run(
        () => service.attemptWithReceipt(domain),
      );
      expect(result.outcome, AutomaticLoginOutcome.failed);
      expect(result.receipt, isNull);
    }
    expect(recognizer.lengths, isEmpty);
    expect(context.expectedEpochs, isEmpty);
  });

  test('后台起始 epoch 或账号变化时不接受新账号凭据', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();
    final epoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );
    final stale = BackgroundAuthContext(mayContinue: () async => true)
      ..expectedEpochs[AuthRecoveryDomain.cas.wireName] = epoch - 1
      ..expectedAccounts[AuthRecoveryDomain.cas.wireName] = 'A';
    final result = await stale.run(
      () => service.attemptWithReceipt(AuthRecoveryDomain.cas),
    );
    expect(result.outcome, AutomaticLoginOutcome.notEligible);
    final changed = BackgroundAuthContext(mayContinue: () async => true)
      ..expectedEpochs[AuthRecoveryDomain.cas.wireName] = epoch
      ..expectedAccounts[AuthRecoveryDomain.cas.wireName] = 'B';
    final other = await changed.run(
      () => service.attemptWithReceipt(
        AuthRecoveryDomain.cas,
        expectedAccount: 'A',
      ),
    );
    expect(other.outcome, AutomaticLoginOutcome.notEligible);
    expect(adapter.loginPosts, 0);
    expect(recognizer.lengths, isEmpty);
  });

  test('后台 CAS 真实提交才推进本轮期望 epoch', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();
    final context = BackgroundAuthContext(mayContinue: () async => true);
    final result = await context.run(
      () => service.attemptWithReceipt(AuthRecoveryDomain.cas),
    );
    expect(result.outcome, AutomaticLoginOutcome.committed);
    expect(
      context.expectedEpochs[AuthRecoveryDomain.cas.wireName],
      result.receipt!.epoch,
    );
    expect(
      context.expectedEpochs[AuthRecoveryDomain.academic.wireName],
      isNull,
    );
  });

  test('后台本轮自己判失效撤销 CAS 后，同账号恢复仍可提交', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();
    final epoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );
    final context = BackgroundAuthContext(mayContinue: () async => true)
      ..expectedEpochs[AuthRecoveryDomain.cas.wireName] = epoch
      ..expectedAccounts[AuthRecoveryDomain.cas.wireName] = 'A';
    final result = await context.run(() async {
      // WebVPN 网关校验判失效 → markLoggedOut → revoke 推进 epoch。
      await AuthSessionPersistence.instance.revoke(
        CredentialSessionDomain.unified,
      );
      return service.attemptWithReceipt(AuthRecoveryDomain.cas);
    });
    expect(result.outcome, AutomaticLoginOutcome.committed);
    expect(adapter.loginPosts, 1);
    expect(result.receipt!.epoch, epoch + 2);
    expect(context.expectedEpochs[AuthRecoveryDomain.cas.wireName], epoch + 2);
  });

  test('后台让位取消在途 OCR，迟到答案不得提交', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();
    final held = Completer<void>();
    recognizer = _FakeRecognizer(answer: '1234', gate: held);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    final context = BackgroundAuthContext(mayContinue: () async => true);
    final pending = context.run(
      () => service.attemptWithReceipt(AuthRecoveryDomain.cas),
    );
    await recognizer.started.future;
    context.cancelToken.cancel('foreground returned');
    held.complete();
    final result = await pending;
    expect(result.receipt, isNull);
    expect(adapter.loginPosts, 0);
    expect(context.expectedEpochs, isEmpty);
  });

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
      (await AuthRecoveryStateStore.instance.read(AuthRecoveryDomain.cas))
          .activeAttempt,
      isNull,
    );
  });

  test('attemptWithReceipt 暴露真实提交 receipt（CAS）', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();

    final result = await service.attemptWithReceipt(AuthRecoveryDomain.cas);

    expect(result.outcome, AutomaticLoginOutcome.committed);
    expect(result.receipt, isNotNull, reason: 'committed 必须带真实 receipt');
    expect(result.receipt!.account, 'A');
    final envelope = await CredentialStore.instance.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(envelope.active, isTrue);
    expect(envelope.epoch, result.receipt!.epoch);
  });

  test('attemptWithReceipt 非提交终态不携带 receipt', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    recognizer = _FakeRecognizer(answer: null);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();

    final result = await service.attemptWithReceipt(AuthRecoveryDomain.cas);

    expect(result.outcome, AutomaticLoginOutcome.failed);
    expect(result.receipt, isNull, reason: '无真实提交不得携带 receipt');
  });

  test('OCR 返回 null：每张验证码只识别一次，耗尽次数后瞬时退避', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    recognizer = _FakeRecognizer(answer: null);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();

    final outcome = await service.attempt(AuthRecoveryDomain.cas);

    expect(outcome, AutomaticLoginOutcome.failed);
    expect(recognizer.lengths, <int>[4, 4, 4, 4], reason: '每张图固定 4 位、只识别一次');
    expect(adapter.loginPosts, 0, reason: '未识别不得提交登录');
    expect(adapter.captchaGets, 4, reason: '每次重试必须换一张全新验证码');
    final record = await AuthRecoveryStateStore.instance.read(
      AuthRecoveryDomain.cas,
    );
    expect(record.failureCount, 0, reason: 'OCR 认错 ≠ 身份错');
    expect(record.cooldownUntil, isNotNull, reason: '瞬时失败必须退避');
  });

  test('验证码被服务端拒绝后换新验证码重试，第四次提交成功', () async {
    final adapter = _FakeCasAdapter(
      loginBodies: <String>[
        '<html><div id="msg">验证码错误!</div></html>',
        '<html><div id="msg">验证码错误!</div></html>',
        '<html><div id="msg">验证码错误!</div></html>',
        '<html>登录中</html>',
      ],
    );
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    recognizer = _FakeRecognizer(answer: '1234');
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();

    final result = await service.attemptWithReceipt(AuthRecoveryDomain.cas);

    expect(result.outcome, AutomaticLoginOutcome.committed);
    expect(result.receipt, isNotNull);
    expect(adapter.loginPosts, 4, reason: '前三张验证码被拒后继续尝试');
    expect(adapter.captchaGets, 4, reason: '重试使用全新验证码');
    expect(recognizer.lengths, <int>[4, 4, 4, 4]);
    final record = await AuthRecoveryStateStore.instance.read(
      AuthRecoveryDomain.cas,
    );
    expect(record.failureCount, 0, reason: '验证码拒绝不是身份失败');
  });

  test('教务域使用固定 6 位；未识别时换新验证码直到耗尽次数', () async {
    DioClient.instance.dio.httpClientAdapter = _FakeAcademicAdapter();
    recognizer = _FakeRecognizer(answer: null);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveCredentials('2025000001', 'pw');
    await enableAcademicOptIn();

    final outcome = await service.attempt(AuthRecoveryDomain.academic);

    expect(outcome, AutomaticLoginOutcome.failed);
    expect(recognizer.lengths, <int>[6, 6, 6, 6], reason: '教务固定 6 位，每张图只识别一次');
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

  test('同域并发共享同一次交换与真实 receipt', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    final gate = Completer<void>();
    recognizer = _FakeRecognizer(answer: '1234', gate: gate);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();

    final first = service.attempt(AuthRecoveryDomain.cas);
    await recognizer.started.future;

    final second = service.attempt(AuthRecoveryDomain.cas);
    expect(recognizer.lengths, <int>[4], reason: '第二次不得再发起识别');

    gate.complete();
    expect(await first, AutomaticLoginOutcome.committed);
    expect(await second, AutomaticLoginOutcome.committed);
    expect(adapter.loginPosts, 1);
  });

  for (final cancelFirst in <bool>[true, false]) {
    test('取消${cancelFirst ? "首个" : "后加入的"}等待者不取消共享登录', () async {
      final adapter = _FakeCasAdapter();
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      final gate = Completer<void>();
      recognizer = _FakeRecognizer(answer: '1234', gate: gate);
      service = AutomaticLoginService.debugNew(recognizer: recognizer);
      await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
      await enableCasOptIn();
      final firstToken = CancelToken();
      final secondToken = CancelToken();
      final first = service.attemptWithReceipt(
        AuthRecoveryDomain.cas,
        cancelToken: firstToken,
      );
      await recognizer.started.future;
      final second = service.attemptWithReceipt(
        AuthRecoveryDomain.cas,
        cancelToken: secondToken,
      );
      (cancelFirst ? firstToken : secondToken).cancel();
      expect(
        (await (cancelFirst ? first : second)).outcome,
        AutomaticLoginOutcome.failed,
      );
      gate.complete();
      final surviving = await (cancelFirst ? second : first);
      expect(surviving.outcome, AutomaticLoginOutcome.committed);
      expect(surviving.receipt, isNotNull);
      expect(adapter.loginPosts, 1);
      expect(recognizer.lengths, <int>[4]);
    });
  }

  test('所有等待者取消后不提交迟到 OCR，也不记录冷却', () async {
    final adapter = _FakeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    final gate = Completer<void>();
    recognizer = _FakeRecognizer(answer: '1234', gate: gate);
    service = AutomaticLoginService.debugNew(recognizer: recognizer);
    await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
    await enableCasOptIn();
    final tokens = <CancelToken>[CancelToken(), CancelToken()];
    final first = service.attempt(
      AuthRecoveryDomain.cas,
      cancelToken: tokens[0],
    );
    await recognizer.started.future;
    final second = service.attempt(
      AuthRecoveryDomain.cas,
      cancelToken: tokens[1],
    );
    for (final token in tokens) {
      token.cancel();
    }
    expect(await first, AutomaticLoginOutcome.failed);
    expect(await second, AutomaticLoginOutcome.failed);
    gate.complete();
    // Exchange remains non-reentrant until the canceled OCR actually settles.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final record = await AuthRecoveryStateStore.instance.read(
      AuthRecoveryDomain.cas,
    );
    expect(record.activeAttempt, isNull);
    expect(record.cooldownUntil, isNull);
    expect(record.failureCount, 0);
    expect(adapter.loginPosts, 0);
    expect(
      await service.attempt(AuthRecoveryDomain.cas),
      AutomaticLoginOutcome.committed,
    );
  });

  test(
    'server-confirmed password rejection increments identity failure once',
    () async {
      final adapter = _FakeCasAdapter();
      adapter.registerText('POST', '/cas/login', '<html>用户名或密码错误</html>');
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
      await enableCasOptIn();
      expect(
        await service.attempt(AuthRecoveryDomain.cas),
        AutomaticLoginOutcome.failed,
      );
      expect(
        adapter.requestLog.where((entry) => entry == 'POST /cas/login').length,
        1,
        reason: '密码错误不得换验证码重试',
      );
      expect(adapter.captchaGets, 1);
      final record = await AuthRecoveryStateStore.instance.read(
        AuthRecoveryDomain.cas,
      );
      expect(record.failureCount, 1);
      expect(record.cooldownUntil, isNotNull);
    },
  );

  test(
    'leaving foreground cancels a held OCR and cannot submit its late answer',
    () async {
      final adapter = _FakeCasAdapter();
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      final gate = Completer<void>();
      recognizer = _FakeRecognizer(answer: '1234', gate: gate);
      service = AutomaticLoginService.debugNew(recognizer: recognizer);
      await CredentialStore.instance.saveUnifiedAuthCredentials('A', 'pw');
      await enableCasOptIn();
      final pending = service.attempt(AuthRecoveryDomain.cas);
      await recognizer.started.future;
      service.setForeground(false);
      gate.complete();
      expect(await pending, AutomaticLoginOutcome.failed);
      expect(adapter.loginPosts, 0);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      final record = await AuthRecoveryStateStore.instance.read(
        AuthRecoveryDomain.cas,
      );
      expect(record.cooldownUntil, isNull);
      expect(record.activeAttempt, isNull);
      service.setForeground(true);
      expect(
        await service.attempt(AuthRecoveryDomain.cas),
        AutomaticLoginOutcome.committed,
      );
    },
  );

  group('AcademicAuthGuard 触发', () {
    test('自动登录提交成功后重试原请求一次', () async {
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            expect(domain, AuthRecoveryDomain.academic);
            final epoch = await AuthSessionPersistence.instance.readEpoch(
              CredentialSessionDomain.academic,
            );
            final receipt = await AuthSessionPersistence.instance.commit(
              CredentialSessionDomain.academic,
              account: '2025000001',
              expectedEpoch: epoch,
            );
            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: '2025000001',
              forceRevision: true,
            );
            return AutomaticLoginAttemptResult(
              outcome: AutomaticLoginOutcome.committed,
              receipt: receipt,
            );
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
      AcademicAuthGuard.debugAutomaticLoginOverride = (
        domain, {
        String? expectedAccount,
      }) async => AutomaticLoginOutcome.manualRequired;
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
      AcademicAuthGuard.debugAutomaticLoginOverride = (
        domain, {
        String? expectedAccount,
      }) async => AutomaticLoginOutcome.manualRequired;

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
