import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_failure.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/captcha_challenge.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/shared/widgets/login_widget.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    // FakeAsync 区内 path_provider 的目录解析不会完成；Cookie 已切内存存储，
    // 这里只需提供一个不触真实 I/O 的目录字符串，再完成共享 Dio 初始化。
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        '${Directory.systemTemp.path}${Platform.pathSeparator}$folderName/';
    await DioClient.instance.ensureInitialized();
  });

  tearDown(() {
    ZhengfangAuth.instance.debugReset();
  });

  Uint8List tinyPng() => Uint8List.fromList(const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  Widget buildSubject({
    required Future<bool> Function() directReachabilityChecker,
    required Future<bool> Function() webVpnReachabilityChecker,
    required Future<bool?> Function() gatewaySessionEnsurer,
    required Future<Uint8List> Function() captchaLoader,
    required Future<LoginResult> Function(String, String, String) loginHandler,
    required VoidCallback onLoginSuccess,
    UnifiedAuthStageBuilder? unifiedAuthStageBuilder,
    AcademicModeSetter? modeSetter,
    AcademicCredentialSaver? credentialSaver,
    AcademicCredentialClearer? credentialClearer,
    AcademicAutoLoginEnabler? enableAutoLogin,
    AcademicAutoLoginSuccessRecorder? recordAutoLoginSuccess,
    AcademicAutoLoginDisabler? disableAutoLogin,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LoginWidget(
          onLoginSuccess: onLoginSuccess,
          directReachabilityChecker: directReachabilityChecker,
          webVpnReachabilityChecker: webVpnReachabilityChecker,
          gatewaySessionEnsurer: gatewaySessionEnsurer,
          captchaLoader: captchaLoader,
          loginHandler: loginHandler,
          credentialLoader: () async => ('20250001', 'academic-password'),
          credentialSaver: credentialSaver ?? (_, _) async {},
          credentialClearer: credentialClearer ?? () async {},
          enableAutoLogin:
              enableAutoLogin ?? (_) async => AuthRecoveryEnableResult.enabled,
          recordAutoLoginSuccess: recordAutoLoginSuccess ?? () async {},
          disableAutoLogin: disableAutoLogin ?? () async {},
          modeSetter: modeSetter ?? (_) {},
          unifiedAuthStageBuilder: unifiedAuthStageBuilder,
        ),
      ),
    );
  }

  CaptchaChallenge challenge(String id) => CaptchaChallenge(
    id: id,
    bytes: tinyPng(),
    createdAt: DateTime.now(),
    domain: CaptchaChallengeDomain.zhengfang,
    accountRevision: 1,
  );

  Widget buildChallengeSubject({
    required AcademicChallengeLoader challengeLoader,
    AcademicChallengeLoginHandler? challengeLoginHandler,
    AcademicChallengeInvalidator? challengeInvalidator,
    Future<bool> Function()? directReachabilityChecker,
    VoidCallback? onLoginSuccess,
    AcademicCredentialSaver? credentialSaver,
    AcademicCredentialClearer? credentialClearer,
    AcademicAutoLoginEnabler? enableAutoLogin,
    AcademicAutoLoginSuccessRecorder? recordAutoLoginSuccess,
    AcademicAutoLoginDisabler? disableAutoLogin,
    bool useRealAutoLoginHooks = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LoginWidget(
          onLoginSuccess: onLoginSuccess ?? () {},
          directReachabilityChecker:
              directReachabilityChecker ?? () async => true,
          webVpnReachabilityChecker: () async => false,
          gatewaySessionEnsurer: () async => false,
          challengeLoader: challengeLoader,
          challengeLoginHandler: challengeLoginHandler,
          challengeInvalidator: challengeInvalidator,
          credentialLoader: () async => ('20250001', 'academic-password'),
          credentialSaver: credentialSaver ?? (_, _) async {},
          credentialClearer: credentialClearer ?? () async {},
          enableAutoLogin: useRealAutoLoginHooks
              ? null
              : (enableAutoLogin ??
                    (_) async => AuthRecoveryEnableResult.enabled),
          recordAutoLoginSuccess: useRealAutoLoginHooks
              ? null
              : (recordAutoLoginSuccess ?? () async {}),
          disableAutoLogin: useRealAutoLoginHooks
              ? null
              : (disableAutoLogin ?? () async {}),
          modeSetter: (_) {},
        ),
      ),
    );
  }

  testWidgets('direct mode opens the academic login form immediately', (
    tester,
  ) async {
    ZhengfangMode? selectedMode;

    await tester.pumpWidget(
      buildSubject(
        directReachabilityChecker: () async => true,
        webVpnReachabilityChecker: () async => false,
        gatewaySessionEnsurer: () async => false,
        captchaLoader: () async => tinyPng(),
        loginHandler: (_, _, _) async => LoginFailure('unused'),
        onLoginSuccess: () {},
        modeSetter: (mode) => selectedMode = mode,
      ),
    );
    await tester.pumpAndSettle();

    expect(selectedMode, ZhengfangMode.direct);
    expect(find.text('教务系统密码'), findsOneWidget);
    expect(find.text('第 1 步：一卡通认证'), findsNothing);
    expect(find.text('第 2 步：教务系统登录'), findsNothing);
  });

  testWidgets('webvpn mode completes CAS before academic login', (
    tester,
  ) async {
    var gatewayChecks = 0;
    var captchaLoads = 0;
    var academicLoginCalls = 0;
    var loginSucceeded = false;

    await tester.pumpWidget(
      buildSubject(
        directReachabilityChecker: () async => false,
        webVpnReachabilityChecker: () async => true,
        gatewaySessionEnsurer: () async {
          gatewayChecks += 1;
          return gatewayChecks > 1;
        },
        captchaLoader: () async {
          captchaLoads += 1;
          return tinyPng();
        },
        loginHandler: (username, password, captcha) async {
          academicLoginCalls += 1;
          expect(username, '20250001');
          expect(password, 'academic-password');
          expect(captcha, 'abcd');
          return LoginSuccess();
        },
        onLoginSuccess: () => loginSucceeded = true,
        unifiedAuthStageBuilder: (context, onLoginSuccess) {
          return FilledButton(
            onPressed: onLoginSuccess,
            child: const Text('模拟一卡通认证成功'),
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第 1 步：一卡通认证'), findsOneWidget);
    expect(find.text('模拟一卡通认证成功'), findsOneWidget);
    expect(find.text('教务系统密码'), findsNothing);
    expect(captchaLoads, 0);
    expect(academicLoginCalls, 0);
    expect(loginSucceeded, isFalse);

    await tester.tap(find.text('模拟一卡通认证成功'));
    await tester.pumpAndSettle();

    expect(find.text('第 2 步：教务系统登录'), findsOneWidget);
    expect(find.text('教务系统密码'), findsOneWidget);
    expect(captchaLoads, 1);
    expect(academicLoginCalls, 0);
    expect(loginSucceeded, isFalse);

    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(academicLoginCalls, 1);
    expect(loginSucceeded, isTrue);
  });

  testWidgets(
    'active webvpn gateway skips CAS but still requires academic login',
    (tester) async {
      var captchaLoads = 0;

      await tester.pumpWidget(
        buildSubject(
          directReachabilityChecker: () async => false,
          webVpnReachabilityChecker: () async => true,
          gatewaySessionEnsurer: () async => true,
          captchaLoader: () async {
            captchaLoads += 1;
            return tinyPng();
          },
          loginHandler: (_, _, _) async => LoginFailure('unused'),
          onLoginSuccess: () {},
          unifiedAuthStageBuilder: (context, onLoginSuccess) {
            return const Text('不应显示一卡通表单');
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('不应显示一卡通表单'), findsNothing);
      expect(find.text('第 2 步：教务系统登录'), findsOneWidget);
      expect(captchaLoads, 1);
    },
  );

  testWidgets('failed gateway verification stops instead of looping CAS', (
    tester,
  ) async {
    var gatewayChecks = 0;
    var captchaLoads = 0;

    await tester.pumpWidget(
      buildSubject(
        directReachabilityChecker: () async => false,
        webVpnReachabilityChecker: () async => true,
        gatewaySessionEnsurer: () async {
          gatewayChecks += 1;
          return false;
        },
        captchaLoader: () async {
          captchaLoads += 1;
          return tinyPng();
        },
        loginHandler: (_, _, _) async => LoginFailure('unused'),
        onLoginSuccess: () {},
        unifiedAuthStageBuilder: (context, onLoginSuccess) {
          return FilledButton(
            onPressed: onLoginSuccess,
            child: const Text('模拟一卡通认证成功'),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('模拟一卡通认证成功'));
    await tester.pumpAndSettle();

    expect(gatewayChecks, 2);
    expect(captchaLoads, 0);
    expect(find.text('重新检测'), findsOneWidget);
    expect(find.text('一卡通认证完成，但 WebVPN 会话校验失败，请重新检测'), findsOneWidget);
  });

  testWidgets('challenge: image A -> refresh B, submit only uses B.id', (
    tester,
  ) async {
    var loadIndex = 0;
    String? submittedChallengeId;

    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) async {
          loadIndex++;
          return loadIndex == 1
              ? challenge('challenge-A')
              : challenge('challenge-B');
        },
        challengeLoginHandler:
            ({
              required challengeId,
              required username,
              required password,
              required captcha,
              cancelToken,
            }) async {
              submittedChallengeId = challengeId;
              return LoginSuccess();
            },
      ),
    );
    await tester.pumpAndSettle();
    expect(loadIndex, 1);
    expect(find.byType(Image), findsOneWidget);

    // Tap the captcha image to refresh to B.
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(loadIndex, 2);

    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
    await tester.pumpAndSettle();

    expect(submittedChallengeId, 'challenge-B');
  });

  testWidgets(
    'challenge: late A does not overwrite B and is invalidated by its id',
    (tester) async {
      final completerA = Completer<CaptchaChallenge>();
      final invalidatedIds = <String>[];
      var loadCount = 0;
      String? submittedChallengeId;

      await tester.pumpWidget(
        buildChallengeSubject(
          challengeLoader: ({cancelToken}) {
            loadCount++;
            if (loadCount == 1) return completerA.future;
            return Future.value(challenge('challenge-B'));
          },
          challengeLoginHandler:
              ({
                required challengeId,
                required username,
                required password,
                required captcha,
                cancelToken,
              }) async {
                submittedChallengeId = challengeId;
                return LoginSuccess();
              },
          challengeInvalidator: (id) => invalidatedIds.add(id),
        ),
      );
      await tester.pump();
      expect(loadCount, 1);

      // 20s preparation budget expires before A resolves.
      await tester.pump(const Duration(seconds: 20));
      expect(find.textContaining('请求超时'), findsOneWidget);

      // Retry loads B.
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(loadCount, 2);
      expect(invalidatedIds, isEmpty);

      // Late A must be invalidated by its own id, never B's.
      completerA.complete(challenge('challenge-A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(invalidatedIds, ['challenge-A']);

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      await tester.pumpAndSettle();

      expect(submittedChallengeId, 'challenge-B');
    },
  );

  testWidgets('challenge: late challenge after dispose is invalidated by id', (
    tester,
  ) async {
    final completer = Completer<CaptchaChallenge>();
    final invalidatedIds = <String>[];

    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) => completer.future,
        challengeInvalidator: (id) => invalidatedIds.add(id),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    completer.complete(challenge('late-owned-id'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(invalidatedIds, ['late-owned-id']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('challenge: late challenge after timeout is invalidated by id', (
    tester,
  ) async {
    final completer = Completer<CaptchaChallenge>();
    final invalidatedIds = <String>[];

    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) => completer.future,
        challengeInvalidator: (id) => invalidatedIds.add(id),
      ),
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 20));

    completer.complete(challenge('late-timeout-id'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(invalidatedIds, ['late-timeout-id']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('challenge: closing page invalidates only its own challenge id', (
    tester,
  ) async {
    final invalidatedIds = <String>[];

    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) async =>
            challenge('challenge-owned-123'),
        challengeInvalidator: (id) => invalidatedIds.add(id),
      ),
    );
    await tester.pumpAndSettle();
    expect(invalidatedIds, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(invalidatedIds, ['challenge-owned-123']);
  });

  testWidgets('challenge: refresh during submit does not cause race', (
    tester,
  ) async {
    var loaderCalls = 0;
    var submitCalls = 0;
    final submitCompleter = Completer<LoginResult>();

    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) async {
          loaderCalls++;
          return challenge('challenge-stable');
        },
        challengeLoginHandler:
            ({
              required challengeId,
              required username,
              required password,
              required captcha,
              cancelToken,
            }) {
              submitCalls++;
              return submitCompleter.future;
            },
      ),
    );
    await tester.pumpAndSettle();
    expect(loaderCalls, 1);

    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
    await tester.pump();
    expect(submitCalls, 1);

    // Refresh and re-submit are both blocked while submitting.
    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(loaderCalls, 1);
    expect(submitCalls, 1);

    submitCompleter.complete(LoginSuccess());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'challenge: staleOperation failure refreshes captcha and shows message',
    (tester) async {
      var loaderCalls = 0;

      await tester.pumpWidget(
        buildChallengeSubject(
          challengeLoader: ({cancelToken}) async {
            loaderCalls++;
            return loaderCalls == 1
                ? challenge('challenge-stale-A')
                : challenge('challenge-fresh-B');
          },
          challengeLoginHandler:
              ({
                required challengeId,
                required username,
                required password,
                required captcha,
                cancelToken,
              }) async => LoginFailure(
                '验证码已失效，请刷新后重试',
                kind: AuthFailureKind.staleOperation,
              ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loaderCalls, 1);

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      await tester.pumpAndSettle();

      expect(find.text('验证码已失效，请刷新后重试'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller?.text,
        isEmpty,
      );
      expect(loaderCalls, 2);
      expect(find.text('验证码已失效，请刷新后重试'), findsOneWidget);
    },
  );

  testWidgets(
    'challenge: production default service path carries challenge id without fallback',
    (tester) async {
      final adapter = MockHttpClientAdapter()
        ..register(
          'GET',
          '/jwglxt/xtgl/login_slogin.html',
          (options) async => ResponseBody.fromString(
            '<html><input type="hidden" id="csrftoken" '
            'name="csrftoken" value="csrf-token-123" /></html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            },
          ),
        )
        ..register(
          'GET',
          '/jwglxt/kaptcha',
          (options) async => ResponseBody.fromBytes(
            tinyPng(),
            200,
            headers: {
              Headers.contentTypeHeader: ['image/png'],
            },
          ),
        )
        ..register(
          'GET',
          '/jwglxt/xtgl/login_getPublicKey.html',
          (options) async => ResponseBody.fromString(
            '{"modulus":"18vI4XcZMDybHwuQYgp+fxR8kAgAQWPnKFNLVDoTopVtDgtb1PlyJ'
            'AmV85T1TVUmTVCGqw1adAmVgdDm3MaAO+CrS6bsfywyqMqT8yTNadF79hkFqf3DW0P'
            'UCWk59/vfc8QRnPyJBAIN6pNmukJxdL2Z4WLuQ4e63VivUoacFeE=","exponent":"AQAB"}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          ),
        )
        ..register(
          'POST',
          '/jwglxt/xtgl/login_slogin.html',
          (options) async => ResponseBody.fromString(
            '<html><div id="tips">用户名或密码错误</div></html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            },
          ),
        );

      DioClient.instance.dio.httpClientAdapter = adapter;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LoginWidget(
              onLoginSuccess: () {},
              directReachabilityChecker: () async => true,
              webVpnReachabilityChecker: () async => false,
              gatewaySessionEnsurer: () async => false,
              credentialLoader: () async => ('20250001', 'academic-password'),
              credentialSaver: (_, _) async {},
              modeSetter: (_) {},
            ),
          ),
        ),
      );

      // 生产路径 prepare 由真实 service 建立 challenge：可控 pump 直到图片就绪，
      // 不绕过 prepareCaptchaChallenge（加载中 spinner 会持续调度帧，故不用无界
      // pumpAndSettle）。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byType(Image).evaluate().isNotEmpty) break;
      }
      expect(find.byType(Image), findsOneWidget);
      expect(ZhengfangAuth.instance.hasActiveCaptchaChallenge, isTrue);

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 真实 submitCaptchaChallenge 使用该 id 完成往返，服务端失败页被解析展示。
      expect(find.text('用户名或密码错误'), findsOneWidget);
      expect(
        adapter.requestLog,
        contains('POST /jwglxt/xtgl/login_slogin.html'),
      );
    },
  );

  // ── 记住账号并自动登录（academic 域） ─────────────────────────────────

  testWidgets(
    'remember-account defaults to checked and saves credentials + enables academic recovery',
    (tester) async {
      final saved = <(String, String)>[];
      String? enabledAccount;
      var recordSuccessCalls = 0;
      var clearCalls = 0;
      var disableCalls = 0;
      var loginSucceeded = false;

      await tester.pumpWidget(
        buildChallengeSubject(
          challengeLoader: ({cancelToken}) async =>
              challenge('challenge-remember'),
          challengeLoginHandler: ({
            required challengeId,
            required username,
            required password,
            required captcha,
            cancelToken,
          }) async => LoginSuccess(),
          onLoginSuccess: () => loginSucceeded = true,
          credentialSaver: (username, password) async =>
              saved.add((username, password)),
          credentialClearer: () async => clearCalls++,
          enableAutoLogin: (account) async {
            enabledAccount = account;
            return AuthRecoveryEnableResult.enabled;
          },
          recordAutoLoginSuccess: () async => recordSuccessCalls++,
          disableAutoLogin: () async => disableCalls++,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(saved, [('20250001', 'academic-password')]);
      expect(enabledAccount, '20250001');
      expect(recordSuccessCalls, 1);
      expect(clearCalls, 0);
      expect(disableCalls, 0);
    },
  );

  testWidgets(
    'unchecking remember-account clears credentials and disables academic recovery',
    (tester) async {
      final saved = <(String, String)>[];
      String? enabledAccount;
      var recordSuccessCalls = 0;
      var clearCalls = 0;
      var disableCalls = 0;
      var loginSucceeded = false;

      await tester.pumpWidget(
        buildChallengeSubject(
          challengeLoader: ({cancelToken}) async =>
              challenge('challenge-optout'),
          challengeLoginHandler: ({
            required challengeId,
            required username,
            required password,
            required captcha,
            cancelToken,
          }) async => LoginSuccess(),
          onLoginSuccess: () => loginSucceeded = true,
          credentialSaver: (username, password) async =>
              saved.add((username, password)),
          credentialClearer: () async => clearCalls++,
          enableAutoLogin: (account) async {
            enabledAccount = account;
            return AuthRecoveryEnableResult.enabled;
          },
          recordAutoLoginSuccess: () async => recordSuccessCalls++,
          disableAutoLogin: () async => disableCalls++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('记住账号并自动登录'));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(saved, isEmpty);
      expect(enabledAccount, isNull);
      expect(recordSuccessCalls, 0);
      expect(clearCalls, 1);
      expect(disableCalls, 1);
    },
  );

  testWidgets('enable throwing still completes academic login success', (
    tester,
  ) async {
    var loginSucceeded = false;
    var recordSuccessCalls = 0;

    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) async =>
            challenge('challenge-enable-throw'),
        challengeLoginHandler: ({
          required challengeId,
          required username,
          required password,
          required captcha,
          cancelToken,
        }) async => LoginSuccess(),
        onLoginSuccess: () => loginSucceeded = true,
        enableAutoLogin: (_) async => throw StateError('coordinator down'),
        recordAutoLoginSuccess: () async => recordSuccessCalls++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
    await tester.pumpAndSettle();

    expect(loginSucceeded, isTrue);
    expect(recordSuccessCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'non-enabled enable result still completes academic login without recording success',
    (tester) async {
      var loginSucceeded = false;
      var recordSuccessCalls = 0;

      await tester.pumpWidget(
        buildChallengeSubject(
          challengeLoader: ({cancelToken}) async =>
              challenge('challenge-enable-missing'),
          challengeLoginHandler: ({
            required challengeId,
            required username,
            required password,
            required captcha,
            cancelToken,
          }) async => LoginSuccess(),
          onLoginSuccess: () => loginSucceeded = true,
          enableAutoLogin: (_) async =>
              AuthRecoveryEnableResult.credentialsMissing,
          recordAutoLoginSuccess: () async => recordSuccessCalls++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(recordSuccessCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'production default hooks enable academic recovery through the real coordinator',
    (tester) async {
      final domains = <AuthRecoveryDomain>[];
      // 缺失凭据会让真实协调器在触盘前直接返回 credentialsMissing：该测试因此
      // 验证生产默认接线（真调用协调器、域正确）而不写磁盘、不读真实凭据。
      AuthOperationCoordinator.instance.debugCredentialLoader = (domain) async {
        domains.add(domain);
        return null;
      };
      addTearDown(AuthOperationCoordinator.instance.debugReset);

      var loginSucceeded = false;
      await tester.pumpWidget(
        buildChallengeSubject(
          challengeLoader: ({cancelToken}) async =>
              challenge('challenge-production-wiring'),
          challengeLoginHandler: ({
            required challengeId,
            required username,
            required password,
            required captcha,
            cancelToken,
          }) async => LoginSuccess(),
          onLoginSuccess: () => loginSucceeded = true,
          useRealAutoLoginHooks: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(domains, [AuthRecoveryDomain.academic]);
      expect(tester.takeException(), isNull);
    },
  );

  // ── 错误横幅与验证码可点语义（UI 呈现） ─────────────────────────────

  testWidgets('validation failure renders the inline error banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) async => challenge('challenge-banner'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.error_outline), findsNothing);

    // 已预填账号密码，仅验证码为空 → 校验错误进入横幅。
    await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
    await tester.pumpAndSettle();

    expect(find.text('请填写学号、密码和验证码'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captcha block exposes a labeled refresh button', (tester) async {
    final handle = tester.ensureSemantics();
    var challengeLoads = 0;

    await tester.pumpWidget(
      buildChallengeSubject(
        challengeLoader: ({cancelToken}) async {
          challengeLoads += 1;
          return challenge('challenge-semantics');
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('刷新验证码'), findsOneWidget);

    // 外层 Semantics 必须与 InkWell 暴露同一个 tap 动作（InkWell 已关闭语义）。
    final refreshNode = find.semantics.byLabel('刷新验证码');
    expect(refreshNode.evaluate(), hasLength(1));
    expect(
      refreshNode.evaluate().single.getSemanticsData().hasAction(
        SemanticsAction.tap,
      ),
      isTrue,
    );

    // 语义 tap 必须等价于真实点击，触发同一刷新行为。
    tester.semantics.tap(refreshNode);
    await tester.pumpAndSettle();
    expect(challengeLoads, 2);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('captcha refresh exposes no tap action while loading', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final pending = Completer<CaptchaChallenge>();

    await tester.pumpWidget(
      buildChallengeSubject(challengeLoader: ({cancelToken}) => pending.future),
    );
    // 首屏仍在「正在准备验证码」状态，进度动画不会停止，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump();

    // 加载中保留进度提示（帮助行只保留这一条文案）。
    expect(find.text('正在准备教务验证码...'), findsOneWidget);
    expect(find.text('可手动输入，点击图片可换一张'), findsNothing);

    final loadingNode = find.semantics.byLabel('刷新验证码');
    expect(loadingNode.evaluate(), hasLength(1));
    expect(
      loadingNode.evaluate().single.getSemanticsData().hasAction(
        SemanticsAction.tap,
      ),
      isFalse,
    );

    // 收尾：完成挂起的 challenge，退出加载态并避免遗留超时计时器。
    pending.complete(challenge('challenge-semantics-loading'));
    await tester.pumpAndSettle();
    expect(
      find.semantics
          .byLabel('刷新验证码')
          .evaluate()
          .single
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    handle.dispose();
  });

  testWidgets('captcha helper copy is removed once the challenge is ready', (
    tester,
  ) async {
    final pending = Completer<CaptchaChallenge>();

    await tester.pumpWidget(
      buildChallengeSubject(challengeLoader: ({cancelToken}) => pending.future),
    );
    // 首屏仍在准备验证码，进度动画不会停止，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump();

    expect(find.text('正在准备教务验证码...'), findsOneWidget);

    pending.complete(challenge('challenge-helper-ready'));
    await tester.pumpAndSettle();

    // 就绪后帮助行整体隐藏：冗余提示与准备中文案都不再渲染。
    expect(find.text('正在准备教务验证码...'), findsNothing);
    expect(find.text('可手动输入，点击图片可换一张'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
