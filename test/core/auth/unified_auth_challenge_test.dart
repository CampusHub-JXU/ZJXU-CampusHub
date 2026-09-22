import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/auth_failure.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/captcha_challenge.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
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

String _cookieHeader(RequestOptions options) {
  final lower = options.headers['cookie'];
  if (lower != null) return lower.toString();
  final upper = options.headers['Cookie'];
  return upper?.toString() ?? '';
}

String _ltFromBody(Object? data) {
  if (data is Map) return data['lt']?.toString() ?? '';
  final text = data?.toString() ?? '';
  return RegExp(r'(?:^|&)lt=([^&]+)').firstMatch(text)?.group(1) ?? '';
}

/// 有状态 CAS mock：登录页为每个请求签发一个 session nonce 且写入 cookie，
/// POST 只有在「提交的 lt nonce == 请求携带的 CAS_SESSION cookie」时才成功。
/// 若两个 challenge 共享 jar 导致 A/B 串扰，POST 会 mismatch。
class _ChallengeCasAdapter extends MockHttpClientAdapter {
  _ChallengeCasAdapter({
    this.postBody = '<html>登录中</html>',
    this.beforePost,
    this.firstCaptchaGate,
    this.onFirstCaptcha,
  }) {
    var nonce = 0;
    register('GET', '/cas/login', (options) async {
      final n = 'n${nonce++}';
      return ResponseBody.fromString(
        '<html><form id="fm1" action="/cas/login">'
        '<input type="hidden" name="lt" value="LT-$n" />'
        '<input type="hidden" name="execution" value="e1s1" />'
        '</form></html>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
          'set-cookie': <String>['CAS_SESSION=$n; Path=/'],
        },
      );
    });
    register('GET', '/cas/captcha.html', (options) async {
      final isFirst = _captchaCount++ == 0;
      if (isFirst) onFirstCaptcha?.call();
      if (isFirst && firstCaptchaGate != null) {
        await firstCaptchaGate!.future;
      }
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
      if (beforePost != null) await beforePost!();
      final lt = _ltFromBody(options.data);
      final session = RegExp(r'CAS_SESSION=([^;]+)')
          .firstMatch(_cookieHeader(options))
          ?.group(1);
      final expected = lt.startsWith('LT-') ? lt.substring(3) : '';
      if (expected.isEmpty || session != expected) {
        sessionMismatches++;
      }
      return ResponseBody.fromString(
        postBody,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    });
  }

  final String postBody;
  final Future<void> Function()? beforePost;
  final Completer<void>? firstCaptchaGate;
  final void Function()? onFirstCaptcha;
  int sessionMismatches = 0;
  int loginPosts = 0;
  int _captchaCount = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UnifiedAuthService auth;
  late Directory lockDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    auth = UnifiedAuthService.instance;
    auth.debugReset();
    AuthSessionPersistence.instance.debugReset();
    lockDir = await Directory.systemTemp.createTemp('cas_challenge_test_');
    AuthSessionPersistence.instance.debugDirectoryProvider = () async =>
        lockDir;
    AuthRecoveryStateStore.instance
      ..debugReset()
      ..debugDirectoryProvider = () async => lockDir;
    AuthOperationCoordinator.instance.debugReset();
    DioClient.instance.debugUseMemoryCookieStorage = true;
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        '${Directory.systemTemp.path}/jxuc_ua_challenge_test/$folderName/';
    await DioClient.instance.ensureInitialized();
  });

  tearDown(() async {
    auth.debugReset();
    AuthSessionPersistence.instance.debugReset();
    AuthRecoveryStateStore.instance.debugReset();
    AuthOperationCoordinator.instance.debugReset();
    DioClient.instance.debugReset();
    NetworkSettings.instance.debugReset();
    if (await lockDir.exists()) await lockDir.delete(recursive: true);
  });

  test('sessionRevision is exposed and only bumps on identity change', () {
    final initial = auth.sessionRevision;
    auth.debugSetSession(active: true, account: 'A');
    final afterLogin = auth.sessionRevision;
    expect(afterLogin, greaterThan(initial));

    auth.debugSetSession(active: true, account: 'A');
    expect(auth.sessionRevision, afterLogin);

    auth.debugSetSession(active: true, account: 'B');
    expect(auth.sessionRevision, greaterThan(afterLogin));
  });

  test('prepare then submit succeeds once', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();

    final challenge = await auth.prepareCaptchaChallenge();
    expect(challenge, isA<CaptchaChallenge>());
    expect(challenge.bytes, isNotEmpty);
    expect(challenge.domain, CaptchaChallengeDomain.unifiedAuth);
    expect(auth.hasActiveCaptchaChallenge, isTrue);

    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1234',
    );

    expect(result, isA<UnifiedAuthLoginSuccess>());
    expect(auth.isLoggedIn, isTrue);
    expect(auth.currentAccount, 'A');
    expect(
      auth.debugWebViewCookieSyncCalls,
      1,
      reason: '人工登录默认仍同步 WebView Cookie',
    );
  });

  test(
    'interleaved prepare A/B never mixes form and session cookies',
    () async {
      final gate = Completer<void>();
      final firstCaptchaStarted = Completer<void>();
      final adapter = _ChallengeCasAdapter(
        firstCaptchaGate: gate,
        onFirstCaptcha: () {
          if (!firstCaptchaStarted.isCompleted) firstCaptchaStarted.complete();
        },
      );
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      // A 的登录页已取、验证码被卡住。
      final prepareA = auth.prepareCaptchaChallenge();
      await firstCaptchaStarted.future;

      // B 完整跑完（登录页 + 验证码 + arm）；旧共享 jar 设计会让 B 覆盖 cookie。
      await auth.prepareCaptchaChallenge();

      gate.complete();
      final a = await prepareA; // A 最后 arm，成为当前 challenge

      final resultA = await auth.submitCaptchaChallenge(
        challengeId: a.id,
        username: 'A',
        password: 'pw',
        captcha: '1',
      );

      expect(resultA, isA<UnifiedAuthLoginSuccess>());
      expect(
        adapter.sessionMismatches,
        0,
        reason: '共享 jar 会导致 context_A + cookie_B 串扰',
      );
    },
  );

  test('a submitted challenge cannot be replayed', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();
    final challenge = await auth.prepareCaptchaChallenge();

    await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1234',
    );
    final replay = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1234',
    );
    expect(replay, isA<UnifiedAuthLoginFailure>());
    expect(
      (replay as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );
  });

  test('invalidateChallenge by id does not clear a newer challenge', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();
    final a = await auth.prepareCaptchaChallenge();
    final b = await auth.prepareCaptchaChallenge();

    auth.invalidateChallenge(challengeId: a.id);
    expect(auth.hasActiveCaptchaChallenge, isTrue);

    final resultB = await auth.submitCaptchaChallenge(
      challengeId: b.id,
      username: 'A',
      password: 'pw',
      captcha: '1',
    );
    expect(resultB, isA<UnifiedAuthLoginSuccess>());

    auth.invalidateChallenge(challengeId: b.id);
    final stale = await auth.submitCaptchaChallenge(
      challengeId: b.id,
      username: 'A',
      password: 'pw',
      captcha: '1',
    );
    expect(
      (stale as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );
  });

  test('logout before submit invalidates the prepared challenge', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();
    final challenge = await auth.prepareCaptchaChallenge();
    await auth.markLoggedOut();

    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1234',
    );
    expect(
      (result as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );
    expect(auth.isLoggedIn, isFalse);
  });

  test('refresh during submit discards the in-flight result', () async {
    final postGate = Completer<void>();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = _ChallengeCasAdapter(
      beforePost: () => postGate.future,
    );
    final challenge = await auth.prepareCaptchaChallenge();

    final pending = auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1234',
    );
    await Future<void>.delayed(Duration.zero);
    await auth.fetchCaptcha();
    postGate.complete();

    final result = await pending;
    expect(
      (result as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );
    expect(auth.isLoggedIn, isFalse);
  });

  test('logout during submit must not write success metadata', () async {
    final postGate = Completer<void>();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = _ChallengeCasAdapter(
      beforePost: () => postGate.future,
    );
    final challenge = await auth.prepareCaptchaChallenge();

    final notifications = <int>[];
    auth.addListener(() => notifications.add(1));

    final pending = auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1234',
    );
    await Future<void>.delayed(Duration.zero);
    await auth.markLoggedOut();
    postGate.complete();

    final result = await pending;
    expect(
      (result as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );
    expect(auth.isLoggedIn, isFalse);
    expect(auth.currentAccount, isNull);
    expect(notifications.length, 1);
  });

  test('captcha failure html classifies as captchaRejected', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter = _ChallengeCasAdapter(
      postBody: '<div id="msg">验证码错误</div>',
    );
    final challenge = await auth.prepareCaptchaChallenge();
    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '0000',
    );
    expect(
      (result as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.captchaRejected,
    );
  });

  test('manual login compat consumes only the current challenge', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();

    // 无当前 challenge：不得重新初始化上下文。
    final noChallenge = await auth.login('A', 'pw', '1234');
    expect(
      (noChallenge as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );

    final challenge = await auth.prepareCaptchaChallenge();
    final result = await auth.login('A', 'pw', '1234');
    expect(result, isA<UnifiedAuthLoginSuccess>());
    expect(auth.isLoggedIn, isTrue);
    // 已消费，不可重放。
    final replay = await auth.login('A', 'pw', '1234');
    expect(
      (replay as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );
    expect(challenge.id, isNotEmpty);
  });

  test('already-logged-in prepare short-circuits same account only', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();
    auth.debugSetSession(active: true, account: 'A');
    final challenge = await auth.prepareCaptchaChallenge();

    final same = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1',
    );
    expect(same, isA<UnifiedAuthLoginSuccess>());
    expect(auth.currentAccount, 'A');
  });

  test('cancelling prepare stops before arming a challenge', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();
    final token = CancelToken()..cancel('page closed');

    await expectLater(
      auth.prepareCaptchaChallenge(cancelToken: token),
      throwsA(isA<DioException>()),
    );
    expect(auth.hasActiveCaptchaChallenge, isFalse);
  });

  test(
    'durable epoch is bound at prepare: external revoke makes submit stale',
    () async {
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          _ChallengeCasAdapter();
      final challenge = await auth.prepareCaptchaChallenge();
      final revisionBefore = auth.sessionRevision;

      // 模拟另一 isolate 撤销：直接推进持久 epoch 并置 inactive。
      await CredentialStore.instance.clearUnifiedAuthSession();
      expect(
        auth.sessionRevision,
        revisionBefore,
        reason: '内存 revision 不变，必须靠 prepare 固定的持久 epoch 拒绝',
      );

      final result = await auth.submitCaptchaChallenge(
        challengeId: challenge.id,
        username: 'A',
        password: 'pw',
        captcha: '1',
      );
      expect(
        (result as UnifiedAuthLoginFailure).kind,
        AuthFailureKind.staleOperation,
      );
      expect(await CredentialStore.instance.loadUnifiedAuthSession(), isNull);
      expect(auth.isLoggedIn, isFalse);
    },
  );

  test('a winning newer session is not revoked by a stale submit', () async {
    DioClient.instance.unifiedAuthDio.httpClientAdapter =
        _ChallengeCasAdapter();
    final challenge = await auth.prepareCaptchaChallenge();

    // 更新的登录（另一实例）先提交成功。
    await CredentialStore.instance.saveUnifiedAuthSession('B');

    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1',
    );
    expect(
      (result as UnifiedAuthLoginFailure).kind,
      AuthFailureKind.staleOperation,
    );
    // 旧提交的失败绝不能全局撤销新会话。
    final envelope = await CredentialStore.instance.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(envelope.active, isTrue);
    expect(envelope.account, 'B');
  });

  // ── 自动恢复：真实 challenge 提交 → typed ticket commit → runAutomatic ──

  Future<void> enableCasOptIn() => AuthRecoveryStateStore.instance.enable(
    AuthRecoveryDomain.cas,
    account: 'A',
    credentialRevision: 0,
  );

  test(
    'automatic recovery commits once through the real challenge submit',
    () async {
      final adapter = _ChallengeCasAdapter();
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      await enableCasOptIn();
      final epochBefore = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      );

      final outcome = await AuthOperationCoordinator.instance
          .runAutomatic<UnifiedAuthLoginResult>(
            domain: AuthRecoveryDomain.cas,
            account: 'A',
            exchange: (ticket, token) async {
              final challenge = await auth.prepareCaptchaChallenge(
                cancelToken: token,
              );
              return auth.submitCaptchaChallenge(
                challengeId: challenge.id,
                username: 'A',
                password: 'pw',
                captcha: '1234',
                cancelToken: token,
                recoveryTicket: ticket,
                syncWebViewCookies: false,
              );
            },
            receiptOf: (value) =>
                value is UnifiedAuthLoginSuccess ? value.receipt : null,
          );

      expect(outcome.decision, AuthRecoveryDecision.committed);
      expect(outcome.didCommit, isTrue);
      expect(outcome.receipt, isNotNull);
      expect(outcome.receipt!.account, 'A');
      expect(outcome.receipt!.epoch, epochBefore + 1);
      expect(adapter.loginPosts, 1, reason: '真实 challenge 只提交一次');
      expect(adapter.sessionMismatches, 0);

      final envelope = await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.unified,
      );
      expect(envelope.active, isTrue);
      expect(envelope.account, 'A');
      expect(
        envelope.epoch,
        epochBefore + 1,
        reason: '唯一提交点只 merge/推进 epoch 一次',
      );
      expect(auth.isLoggedIn, isTrue);
      expect(
        auth.debugWebViewCookieSyncCalls,
        0,
        reason: '自动路径必须禁止 WebView cookie 同步',
      );
      final record = await AuthRecoveryStateStore.instance.read(
        AuthRecoveryDomain.cas,
      );
      expect(record.activeAttempt, isNull);
      expect(record.manualHoldUntil, isNull);
    },
  );

  test('opt-in disabled before submit never merges the session', () async {
    final adapter = _ChallengeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await enableCasOptIn();
    final epochBefore = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );

    final outcome = await AuthOperationCoordinator.instance
        .runAutomatic<UnifiedAuthLoginResult>(
          domain: AuthRecoveryDomain.cas,
          account: 'A',
          exchange: (ticket, token) async {
            final challenge = await auth.prepareCaptchaChallenge(
              cancelToken: token,
            );
            await AuthRecoveryStateStore.instance.disable(
              AuthRecoveryDomain.cas,
            );
            return auth.submitCaptchaChallenge(
              challengeId: challenge.id,
              username: 'A',
              password: 'pw',
              captcha: '1234',
              cancelToken: token,
              recoveryTicket: ticket,
              syncWebViewCookies: false,
            );
          },
          receiptOf: (value) =>
              value is UnifiedAuthLoginSuccess ? value.receipt : null,
        );

    expect(outcome.didCommit, isFalse);
    expect(
      (await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.unified,
      )).active,
      isFalse,
    );
    expect(
      await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      ),
      epochBefore,
    );
    expect(auth.isLoggedIn, isFalse);
  });

  test(
    'manual lease acquired before submit never merges the session',
    () async {
      final adapter = _ChallengeCasAdapter();
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      await enableCasOptIn();
      final epochBefore = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      );

      final outcome = await AuthOperationCoordinator.instance
          .runAutomatic<UnifiedAuthLoginResult>(
            domain: AuthRecoveryDomain.cas,
            account: 'A',
            exchange: (ticket, token) async {
              final challenge = await auth.prepareCaptchaChallenge(
                cancelToken: token,
              );
              await AuthRecoveryStateStore.instance.beginManualHold(
                AuthRecoveryDomain.cas,
              );
              return auth.submitCaptchaChallenge(
                challengeId: challenge.id,
                username: 'A',
                password: 'pw',
                captcha: '1234',
                cancelToken: token,
                recoveryTicket: ticket,
                syncWebViewCookies: false,
              );
            },
            receiptOf: (value) =>
                value is UnifiedAuthLoginSuccess ? value.receipt : null,
          );

      expect(outcome.didCommit, isFalse);
      expect(
        (await CredentialStore.instance.readSessionEnvelope(
          CredentialSessionDomain.unified,
        )).active,
        isFalse,
      );
      expect(
        await AuthSessionPersistence.instance.readEpoch(
          CredentialSessionDomain.unified,
        ),
        epochBefore,
      );
    },
  );

  test('account switch before submit never merges the session', () async {
    final adapter = _ChallengeCasAdapter();
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await enableCasOptIn();

    final outcome = await AuthOperationCoordinator.instance
        .runAutomatic<UnifiedAuthLoginResult>(
          domain: AuthRecoveryDomain.cas,
          account: 'A',
          exchange: (ticket, token) async {
            final challenge = await auth.prepareCaptchaChallenge(
              cancelToken: token,
            );
            // 另一 isolate / 另一路径切换身份：持久 epoch 前进且置 inactive。
            await CredentialStore.instance.clearUnifiedAuthSession();
            return auth.submitCaptchaChallenge(
              challengeId: challenge.id,
              username: 'A',
              password: 'pw',
              captcha: '1234',
              cancelToken: token,
              recoveryTicket: ticket,
              syncWebViewCookies: false,
            );
          },
          receiptOf: (value) =>
              value is UnifiedAuthLoginSuccess ? value.receipt : null,
        );

    expect(outcome.didCommit, isFalse);
    expect(
      (await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.unified,
      )).active,
      isFalse,
    );
    expect(auth.isLoggedIn, isFalse);
  });

  test('cancelled run never commits a late transport result', () async {
    final gate = Completer<void>();
    final adapter = _ChallengeCasAdapter(beforePost: () => gate.future);
    DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
    await enableCasOptIn();
    final epochBefore = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.unified,
    );

    final outcome = await AuthOperationCoordinator.instance
        .runAutomatic<UnifiedAuthLoginResult>(
          domain: AuthRecoveryDomain.cas,
          account: 'A',
          exchange: (ticket, token) async {
            final challenge = await auth.prepareCaptchaChallenge(
              cancelToken: token,
            );
            return auth.submitCaptchaChallenge(
              challengeId: challenge.id,
              username: 'A',
              password: 'pw',
              captcha: '1234',
              cancelToken: token,
              recoveryTicket: ticket,
              syncWebViewCookies: false,
            );
          },
          receiptOf: (value) =>
              value is UnifiedAuthLoginSuccess ? value.receipt : null,
          exchangeDeadline: const Duration(milliseconds: 20),
          exchangeAbortAfter: const Duration(milliseconds: 300),
        );

    expect(outcome.didCommit, isFalse);

    // 取消后迟到的 transport 结果不得触发提交。
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      (await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.unified,
      )).active,
      isFalse,
    );
    expect(
      await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      ),
      epochBefore,
    );
  });
}
