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
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

import '../../helpers/mock_http_client_adapter.dart';

const _modulus =
    '18vI4XcZMDybHwuQYgp+fxR8kAgAQWPnKFNLVDoTopVtDgtb1PlyJAmV85T1TVUmTVCGqw1adAmVgdDm3MaAO+CrS6bsfywyqMqT8yTNadF79hkFqf3DW0PUCWk59/vfc8QRnPyJBAIN6pNmukJxdL2Z4WLuQ4e63VivUoacFeE=';
const _exponent = 'AQAB';

final Uint8List _png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  5,
  6,
  7,
  8,
]);

String _cookieHeader(RequestOptions options) {
  final lower = options.headers['cookie'];
  if (lower != null) return lower.toString();
  final upper = options.headers['Cookie'];
  return upper?.toString() ?? '';
}

String _fieldFromBody(Object? data, String name) {
  if (data is Map) return data[name]?.toString() ?? '';
  final text = data?.toString() ?? '';
  return RegExp('(?:^|&)$name=([^&]+)').firstMatch(text)?.group(1) ?? '';
}

/// 有状态教务 mock：登录页签发 csrf nonce（token 与 ZF_SESSION cookie 同源），
/// POST 只有二者一致才成功，用于证明 A/B challenge 的 jar 不混。
class _ChallengeZfAdapter extends MockHttpClientAdapter {
  _ChallengeZfAdapter({
    this.beforePost,
    this.firstCaptchaGate,
    this.onFirstCaptcha,
  }) {
    var nonce = 0;
    register('GET', '/jwglxt/xtgl/login_slogin.html', (options) async {
      final n = 'n${nonce++}';
      return ResponseBody.fromString(
        '<html><input type="hidden" id="csrftoken" name="csrftoken" '
        'value="csrf-$n" /></html>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
          'set-cookie': <String>['ZF_SESSION=$n; Path=/'],
        },
      );
    });
    register('GET', '/jwglxt/kaptcha', (options) async {
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
    registerJson('GET', '/jwglxt/xtgl/login_getPublicKey.html', {
      'modulus': _modulus,
      'exponent': _exponent,
    });
    register('POST', '/jwglxt/xtgl/login_slogin.html', (options) async {
      loginPosts++;
      if (beforePost != null) await beforePost!();
      final csrf = _fieldFromBody(options.data, 'csrftoken');
      final session = RegExp(r'ZF_SESSION=([^;]+)')
          .firstMatch(_cookieHeader(options))
          ?.group(1);
      final expected = csrf.startsWith('csrf-') ? csrf.substring(5) : '';
      if (expected.isEmpty || session != expected) {
        sessionMismatches++;
      }
      return ResponseBody.fromString(
        '',
        302,
        headers: <String, List<String>>{
          'location': <String>['/jwglxt/xtgl/index_initMenu.html?jsdm=xs'],
        },
      );
    });
  }

  final Future<void> Function()? beforePost;
  final Completer<void>? firstCaptchaGate;
  final void Function()? onFirstCaptcha;
  int sessionMismatches = 0;
  int loginPosts = 0;
  int _captchaCount = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ZhengfangAuth auth;
  late Directory lockDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    DioClient.instance.debugUseMemoryCookieStorage = true;
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        '${Directory.systemTemp.path}/jxuc_zf_challenge_test/$folderName/';
    auth = ZhengfangAuth.instance;
    auth.debugReset();
    AuthSessionPersistence.instance.debugReset();
    lockDir = await Directory.systemTemp.createTemp('zf_challenge_test_');
    AuthSessionPersistence.instance.debugDirectoryProvider = () async =>
        lockDir;
    AuthRecoveryStateStore.instance
      ..debugReset()
      ..debugDirectoryProvider = () async => lockDir;
    AuthOperationCoordinator.instance.debugReset();
    auth.setMode(ZhengfangMode.direct);
    await DioClient.instance.ensureInitialized();
  });

  tearDown(() async {
    auth.setMode(ZhengfangMode.direct);
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
    auth.debugSetSession(active: true, studentId: 'A');
    final afterLogin = auth.sessionRevision;
    expect(afterLogin, greaterThan(initial));

    auth.debugSetSession(active: true, studentId: 'A');
    expect(auth.sessionRevision, afterLogin);

    auth.debugSetSession(active: true, studentId: 'B');
    expect(auth.sessionRevision, greaterThan(afterLogin));
  });

  test('prepare then submit succeeds once', () async {
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter();

    final challenge = await auth.prepareCaptchaChallenge();
    expect(challenge.domain, CaptchaChallengeDomain.zhengfang);
    expect(challenge.bytes, isNotEmpty);
    expect(auth.hasActiveCaptchaChallenge, isTrue);

    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '2468',
    );

    expect(result, isA<LoginSuccess>());
    expect(auth.isLoggedIn, isTrue);
    expect(auth.currentStudentId, '2024001');
  });

  test(
    'interleaved prepare A/B never mixes csrf and session cookies',
    () async {
      final gate = Completer<void>();
      final firstCaptchaStarted = Completer<void>();
      final adapter = _ChallengeZfAdapter(
        firstCaptchaGate: gate,
        onFirstCaptcha: () {
          if (!firstCaptchaStarted.isCompleted) firstCaptchaStarted.complete();
        },
      );
      DioClient.instance.dio.httpClientAdapter = adapter;

      final prepareA = auth.prepareCaptchaChallenge();
      await firstCaptchaStarted.future;
      await auth.prepareCaptchaChallenge();
      gate.complete();
      final a = await prepareA;

      final resultA = await auth.submitCaptchaChallenge(
        challengeId: a.id,
        username: '2024001',
        password: 'pw',
        captcha: '1',
      );

      expect(resultA, isA<LoginSuccess>());
      expect(adapter.sessionMismatches, 0);
    },
  );

  test('a submitted challenge cannot be replayed', () async {
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter();
    final challenge = await auth.prepareCaptchaChallenge();

    await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '2468',
    );
    final replay = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '2468',
    );
    expect(replay, isA<LoginFailure>());
    expect((replay as LoginFailure).kind, AuthFailureKind.staleOperation);
  });

  test('invalidateChallenge by id does not clear a newer challenge', () async {
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter();
    final a = await auth.prepareCaptchaChallenge();
    final b = await auth.prepareCaptchaChallenge();

    auth.invalidateChallenge(challengeId: a.id);
    expect(auth.hasActiveCaptchaChallenge, isTrue);

    final resultB = await auth.submitCaptchaChallenge(
      challengeId: b.id,
      username: '2024001',
      password: 'pw',
      captcha: '1',
    );
    expect(resultB, isA<LoginSuccess>());
  });

  test('refresh during submit discards the in-flight result', () async {
    final postGate = Completer<void>();
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter(
      beforePost: () => postGate.future,
    );
    final challenge = await auth.prepareCaptchaChallenge();

    final pending = auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '2468',
    );
    await Future<void>.delayed(Duration.zero);
    await auth.fetchCaptcha();
    postGate.complete();

    final result = await pending;
    expect((result as LoginFailure).kind, AuthFailureKind.staleOperation);
    expect(auth.isLoggedIn, isFalse);
  });

  test('logout during submit must not write success metadata', () async {
    final postGate = Completer<void>();
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter(
      beforePost: () => postGate.future,
    );
    final challenge = await auth.prepareCaptchaChallenge();

    final notifications = <int>[];
    auth.addListener(() => notifications.add(1));

    final pending = auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '2468',
    );
    await Future<void>.delayed(Duration.zero);
    await auth.markLoggedOut();
    postGate.complete();

    final result = await pending;
    expect((result as LoginFailure).kind, AuthFailureKind.staleOperation);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.currentStudentId, isNull);
    expect(notifications.length, 1);
  });

  test('mode change after prepare invalidates the challenge', () async {
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter();
    final challenge = await auth.prepareCaptchaChallenge();

    auth.setMode(ZhengfangMode.webVpn);

    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '2468',
    );
    expect((result as LoginFailure).kind, AuthFailureKind.staleOperation);
    expect(auth.isLoggedIn, isFalse);
  });

  test('captcha failure html classifies as captchaRejected', () async {
    final adapter = MockHttpClientAdapter();
    var nonce = 0;
    adapter.register('GET', '/jwglxt/xtgl/login_slogin.html', (options) async {
      final n = 'n${nonce++}';
      return ResponseBody.fromString(
        '<html><input type="hidden" id="csrftoken" name="csrftoken" '
        'value="csrf-$n" /></html>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
          'set-cookie': <String>['ZF_SESSION=$n; Path=/'],
        },
      );
    });
    adapter.register('GET', '/jwglxt/kaptcha', (options) async {
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['image/png'],
        },
      );
    });
    adapter.registerJson('GET', '/jwglxt/xtgl/login_getPublicKey.html', {
      'modulus': _modulus,
      'exponent': _exponent,
    });
    adapter.register('POST', '/jwglxt/xtgl/login_slogin.html', (options) async {
      return ResponseBody.fromString(
        '<div id="tips">验证码错误或已过期</div>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    final challenge = await auth.prepareCaptchaChallenge();
    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '0000',
    );
    expect((result as LoginFailure).kind, AuthFailureKind.captchaRejected);
  });

  test('manual login compat consumes only the current challenge', () async {
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter();

    final noChallenge = await auth.login('2024001', 'pw', '2468');
    expect((noChallenge as LoginFailure).kind, AuthFailureKind.staleOperation);

    await auth.prepareCaptchaChallenge();
    final result = await auth.login('2024001', 'pw', '2468');
    expect(result, isA<LoginSuccess>());
    expect(auth.isLoggedIn, isTrue);
  });

  test(
    'durable epoch is bound at prepare: external revoke makes submit stale',
    () async {
      DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter();
      final challenge = await auth.prepareCaptchaChallenge();
      final revisionBefore = auth.sessionRevision;

      await CredentialStore.instance.clearZhengfangSession();
      expect(
        auth.sessionRevision,
        revisionBefore,
        reason: '内存 revision 不变，必须靠 prepare 固定的持久 epoch 拒绝',
      );

      final result = await auth.submitCaptchaChallenge(
        challengeId: challenge.id,
        username: '2024001',
        password: 'pw',
        captcha: '1',
      );
      expect((result as LoginFailure).kind, AuthFailureKind.staleOperation);
      expect(await CredentialStore.instance.loadZhengfangSession(), isNull);
      expect(auth.isLoggedIn, isFalse);
    },
  );

  test('a winning newer session is not revoked by a stale submit', () async {
    DioClient.instance.dio.httpClientAdapter = _ChallengeZfAdapter();
    final challenge = await auth.prepareCaptchaChallenge();

    await CredentialStore.instance.saveZhengfangSession('B');

    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: 'A',
      password: 'pw',
      captcha: '1',
    );
    expect((result as LoginFailure).kind, AuthFailureKind.staleOperation);
    final envelope = await CredentialStore.instance.readSessionEnvelope(
      CredentialSessionDomain.academic,
    );
    expect(envelope.active, isTrue);
    expect(envelope.account, 'B');
  });

  test('isLoggedIn requires a non-empty student id', () {
    auth.debugSetSession(active: true);
    expect(auth.isLoggedIn, isFalse);

    auth.debugSetSession(active: true, studentId: '2024001');
    expect(auth.isLoggedIn, isTrue);
  });

  test('unknown existing session is not bound to the input account', () async {
    DioClient.instance.dio.httpClientAdapter = _existingSessionZfAdapter();
    final challenge = await auth.prepareCaptchaChallenge();

    final result = await auth.submitCaptchaChallenge(
      challengeId: challenge.id,
      username: '2024001',
      password: 'pw',
      captcha: '1',
    );
    expect((result as LoginFailure).kind, AuthFailureKind.protocolChanged);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.currentStudentId, isNull);
  });

  test(
    'existing session short-circuits only for trusted same account',
    () async {
      auth.debugSetSession(active: true, studentId: '2024001');
      DioClient.instance.dio.httpClientAdapter = _existingSessionZfAdapter();
      final challenge = await auth.prepareCaptchaChallenge();

      final result = await auth.submitCaptchaChallenge(
        challengeId: challenge.id,
        username: '2024001',
        password: 'pw',
        captcha: '1',
      );
      expect(result, isA<LoginSuccess>());
      expect(auth.currentStudentId, '2024001');
      expect(auth.isLoggedIn, isTrue);
    },
  );

  test(
    'existing session does not short-circuit a different username',
    () async {
      auth.debugSetSession(active: true, studentId: 'A');
      DioClient.instance.dio.httpClientAdapter = _existingSessionZfAdapter();
      final challenge = await auth.prepareCaptchaChallenge();

      final result = await auth.submitCaptchaChallenge(
        challengeId: challenge.id,
        username: 'B',
        password: 'pw',
        captcha: '1',
      );
      expect((result as LoginFailure).kind, AuthFailureKind.protocolChanged);
      expect(auth.currentStudentId, 'A');
    },
  );

  // ── 自动恢复：真实 challenge 提交 → typed ticket commit → runAutomatic ──

  Future<void> enableAcademicOptIn() => AuthRecoveryStateStore.instance.enable(
    AuthRecoveryDomain.academic,
    account: '2024001',
    credentialRevision: 0,
  );

  test(
    'automatic recovery commits once through the real challenge submit',
    () async {
      final adapter = _ChallengeZfAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;
      await enableAcademicOptIn();
      final epochBefore = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.academic,
      );

      final outcome = await AuthOperationCoordinator.instance
          .runAutomatic<LoginResult>(
            domain: AuthRecoveryDomain.academic,
            account: '2024001',
            exchange: (ticket, token) async {
              final challenge = await auth.prepareCaptchaChallenge(
                cancelToken: token,
              );
              return auth.submitCaptchaChallenge(
                challengeId: challenge.id,
                username: '2024001',
                password: 'pw',
                captcha: '2468',
                cancelToken: token,
                recoveryTicket: ticket,
              );
            },
            receiptOf: (value) => value is LoginSuccess ? value.receipt : null,
          );

      expect(outcome.decision, AuthRecoveryDecision.committed);
      expect(outcome.didCommit, isTrue);
      expect(outcome.receipt, isNotNull);
      expect(outcome.receipt!.account, '2024001');
      expect(outcome.receipt!.epoch, epochBefore + 1);
      expect(adapter.loginPosts, 1, reason: '真实 challenge 只提交一次');
      expect(adapter.sessionMismatches, 0);

      final envelope = await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.academic,
      );
      expect(envelope.active, isTrue);
      expect(envelope.account, '2024001');
      expect(
        envelope.epoch,
        epochBefore + 1,
        reason: '唯一提交点只 merge/推进 epoch 一次',
      );
      expect(auth.isLoggedIn, isTrue);
      final record = await AuthRecoveryStateStore.instance.read(
        AuthRecoveryDomain.academic,
      );
      expect(record.activeAttempt, isNull);
      expect(record.manualHoldUntil, isNull);
    },
  );

  test(
    'opt-in disabled before submit never merges the academic session',
    () async {
      final adapter = _ChallengeZfAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;
      await enableAcademicOptIn();
      final epochBefore = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.academic,
      );

      final outcome = await AuthOperationCoordinator.instance
          .runAutomatic<LoginResult>(
            domain: AuthRecoveryDomain.academic,
            account: '2024001',
            exchange: (ticket, token) async {
              final challenge = await auth.prepareCaptchaChallenge(
                cancelToken: token,
              );
              await AuthRecoveryStateStore.instance.disable(
                AuthRecoveryDomain.academic,
              );
              return auth.submitCaptchaChallenge(
                challengeId: challenge.id,
                username: '2024001',
                password: 'pw',
                captcha: '2468',
                cancelToken: token,
                recoveryTicket: ticket,
              );
            },
            receiptOf: (value) => value is LoginSuccess ? value.receipt : null,
          );

      expect(outcome.didCommit, isFalse);
      expect(
        (await CredentialStore.instance.readSessionEnvelope(
          CredentialSessionDomain.academic,
        )).active,
        isFalse,
      );
      expect(
        await AuthSessionPersistence.instance.readEpoch(
          CredentialSessionDomain.academic,
        ),
        epochBefore,
      );
      expect(auth.isLoggedIn, isFalse);
    },
  );
}

/// 访问登录入口却重定向到首页的适配器：用于验证未知会话不得绑定输入账号。
MockHttpClientAdapter _existingSessionZfAdapter() {
  return MockHttpClientAdapter()
    ..register('GET', '/jwglxt/xtgl/login_slogin.html', (options) async {
      return ResponseBody.fromString(
        '',
        302,
        headers: <String, List<String>>{
          'location': <String>['/jwglxt/xtgl/index_initMenu.html?jsdm=xs'],
        },
      );
    })
    ..register('GET', '/jwglxt/kaptcha', (options) async {
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['image/png'],
        },
      );
    });
}
