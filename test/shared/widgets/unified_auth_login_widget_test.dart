import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_failure.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/captcha_challenge.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_login_widget.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  setUp(() async {
    await resetTestEnvironment();
    // FakeAsync 区内 path_provider 的目录解析不会完成；Cookie 已切内存存储，
    // 这里只需提供一个不触真实 I/O 的目录字符串，再完成共享 Dio 初始化。
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        '${Directory.systemTemp.path}${Platform.pathSeparator}$folderName/';
    await DioClient.instance.ensureInitialized();
  });

  tearDown(() {
    UnifiedAuthService.instance.debugReset();
  });

  testWidgets('skips captcha when sessionPreflight returns true', (
    tester,
  ) async {
    var loginSucceeded = false;
    var captchaRequested = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () => loginSucceeded = true,
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => true,
            captchaLoader: () async {
              captchaRequested = true;
              return Uint8List(0);
            },
          ),
        ),
      ),
    );

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (loginSucceeded) break;
    }

    expect(loginSucceeded, isTrue);
    expect(captchaRequested, isFalse);
  });

  testWidgets('defaults to direct-first login form for user-facing login', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () async => tinyPng(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('正在检测网络环境...'), findsNothing);
    expect(find.text('一卡通账号'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets(
    'does not auto-succeed when session is active without an account',
    (tester) async {
      var loginSucceeded = false;
      var captchaRequested = false;

      UnifiedAuthService.instance.debugSetSession(active: true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () => loginSucceeded = true,
              loadSavedCredentials: () async => ('', ''),
              sessionPreflight: () async =>
                  UnifiedAuthService.instance.isLoggedIn,
              captchaLoader: () async {
                captchaRequested = true;
                return tinyPng();
              },
              loginHandler: (_, _, _) async => null,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(loginSucceeded, isFalse);
      expect(captchaRequested, isTrue);
      expect(find.text('登录'), findsOneWidget);
    },
  );

  testWidgets(
    'skips network call and captcha when isLoggedIn is already true',
    (tester) async {
      var loginSucceeded = false;
      var captchaRequested = false;

      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '1234567890',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () => loginSucceeded = true,
              loadSavedCredentials: () async => ('', ''),
              captchaLoader: () async {
                captchaRequested = true;
                return Uint8List(0);
              },
            ),
          ),
        ),
      );

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (loginSucceeded) break;
      }

      expect(loginSucceeded, isTrue);
      expect(captchaRequested, isFalse);
    },
  );

  testWidgets('runs preflight before short-circuiting active session', (
    tester,
  ) async {
    var loginSucceeded = false;
    var captchaRequested = false;
    var preflightCalled = false;

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '1234567890',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () => loginSucceeded = true,
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async {
              preflightCalled = true;
              return true;
            },
            captchaLoader: () async {
              captchaRequested = true;
              return Uint8List(0);
            },
          ),
        ),
      ),
    );

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (loginSucceeded) break;
    }

    expect(loginSucceeded, isTrue);
    expect(preflightCalled, isTrue);
    expect(captchaRequested, isFalse);
  });

  testWidgets('hides title block when showHeader is false', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            showHeader: false,
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => true,
          ),
        ),
      ),
    );

    expect(find.text('登录统一认证'), findsNothing);
    expect(find.text('账号为校园一卡通号'), findsNothing);
  });

  testWidgets(
    'shows friendly error when bootstrap throws handshake exception',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () {},
              loadSavedCredentials: () async => ('', ''),
              sessionPreflight: () async {
                throw DioException(
                  requestOptions: RequestOptions(path: '/cas/login'),
                  type: DioExceptionType.unknown,
                  error: HandshakeException(
                    'Connection terminated during handshake',
                  ),
                  message: 'HandshakeException: Connection terminated during handshake',
                );
              },
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('无法连接统一认证，请检查系统代理、VPN 或网络证书环境后重试'), findsOneWidget);
    },
  );

  testWidgets('toggles password visibility from suffix icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () async => tinyPng(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).obscureText,
      isTrue,
    );

    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).obscureText,
      isFalse,
    );
  });

  testWidgets('keeps login failure visible after refreshing captcha', (
    tester,
  ) async {
    var captchaLoads = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('2025000123', 'wrong-password'),
            sessionPreflight: () async => false,
            captchaLoader: () async {
              captchaLoads += 1;
              return tinyPng();
            },
            loginHandler: (_, _, _) async => '账号或密码错误，请检查后重试',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(captchaLoads, 1);

    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(captchaLoads, 2);
    expect(find.text('账号或密码错误，请检查后重试'), findsOneWidget);
  });

  testWidgets('bounds captcha loading and ignores late results after retry', (
    tester,
  ) async {
    final pending = Completer<Uint8List>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            loginHandler: (_, _, _) async => null,
            captchaLoader: () =>
                ++calls == 1 ? pending.future : Future.value(tinyPng()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(find.textContaining('请求超时，请切换网络'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(Image), findsOneWidget);
    pending.completeError(StateError('late failure'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('验证码加载失败'), findsNothing);
  });

  testWidgets('does not issue parallel captcha refreshes', (tester) async {
    final pending = Completer<Uint8List>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            loginHandler: (_, _, _) async => null,
            captchaLoader: () {
              calls++;
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(CircularProgressIndicator));
    await tester.pump();
    expect(calls, 1);
    pending.complete(tinyPng());
    await tester.pumpAndSettle();
  });

  testWidgets('closing login cancels its pending loading deadline', (
    tester,
  ) async {
    final pending = Completer<Uint8List>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () => fail('disposed login must not complete'),
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            loginHandler: (_, _, _) async => null,
            captchaLoader: () => pending.future,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    pending.complete(tinyPng());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('submission exceptions reenable login', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('account', 'password'),
            saveCredentials: (_, _) async {},
            sessionPreflight: () async => false,
            captchaLoader: () async => tinyPng(),
            loginHandler: (_, _, _) async {
              calls++;
              throw TimeoutException('offline');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请求超时，请切换网络'), findsOneWidget);
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('image A -> refresh B, submit only uses B.id', (tester) async {
    var loadIndex = 0;
    String? submittedChallengeId;

    final challengeA = CaptchaChallenge(
      id: 'challenge-A',
      bytes: tinyPng(),
      createdAt: DateTime.now(),
      domain: CaptchaChallengeDomain.unifiedAuth,
      accountRevision: 1,
    );
    final challengeB = CaptchaChallenge(
      id: 'challenge-B',
      bytes: tinyPng(),
      createdAt: DateTime.now(),
      domain: CaptchaChallengeDomain.unifiedAuth,
      accountRevision: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('account', 'password'),
            saveCredentials: (_, _) async {},
            clearCredentials: () async {},
            enableAutoLogin: (_) async => AuthRecoveryEnableResult.enabled,
            recordAutoLoginSuccess: () async {},
            disableAutoLogin: () async {},
            sessionPreflight: () async => false,
            challengeLoader: ({cancelToken}) async {
              loadIndex++;
              return loadIndex == 1 ? challengeA : challengeB;
            },
            challengeSubmitter:
                ({
                  required challengeId,
                  required username,
                  required password,
                  required captcha,
                  cancelToken,
                }) async {
                  submittedChallengeId = challengeId;
                  return UnifiedAuthLoginSuccess();
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loadIndex, 1);

    // Tap to refresh captcha to B
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(loadIndex, 2);

    // Submit
    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(submittedChallengeId, 'challenge-B');
  });

  testWidgets('late A does not overwrite B and is invalidated by its own id', (
    tester,
  ) async {
    final completerA = Completer<CaptchaChallenge>();
    final invalidatedIds = <String>[];
    var loadCount = 0;
    String? submittedChallengeId;

    final challengeB = CaptchaChallenge(
      id: 'challenge-B',
      bytes: tinyPng(),
      createdAt: DateTime.now(),
      domain: CaptchaChallengeDomain.unifiedAuth,
      accountRevision: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('account', 'password'),
            saveCredentials: (_, _) async {},
            sessionPreflight: () async => false,
            challengeLoader: ({cancelToken}) {
              loadCount++;
              if (loadCount == 1) return completerA.future;
              return Future.value(challengeB);
            },
            challengeSubmitter:
                ({
                  required challengeId,
                  required username,
                  required password,
                  required captcha,
                  cancelToken,
                }) async {
                  submittedChallengeId = challengeId;
                  return UnifiedAuthLoginSuccess();
                },
            challengeInvalidator: (id) => invalidatedIds.add(id),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(loadCount, 1);

    // Trigger timeout deadline to show error and refresh button
    await tester.pump(const Duration(seconds: 20));
    expect(find.textContaining('请求超时，请切换网络'), findsOneWidget);

    // Tap retry icon -> issues request B
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(loadCount, 2);
    expect(invalidatedIds, isEmpty);

    // Now late A resolves: it must be invalidated by its own id, never B's.
    completerA.complete(
      CaptchaChallenge(
        id: 'challenge-A',
        bytes: tinyPng(),
        createdAt: DateTime.now(),
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 1,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(invalidatedIds, ['challenge-A']);

    // Submit and assert B was used
    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(submittedChallengeId, 'challenge-B');
  });

  testWidgets(
    'late challenge resolved after dispose is invalidated by its id',
    (tester) async {
      final completer = Completer<CaptchaChallenge>();
      final invalidatedIds = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () {},
              loadSavedCredentials: () async => ('', ''),
              sessionPreflight: () async => false,
              challengeLoader: ({cancelToken}) => completer.future,
              challengeInvalidator: (id) => invalidatedIds.add(id),
            ),
          ),
        ),
      );
      await tester.pump();

      // Close the page before the challenge ever resolves.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      completer.complete(
        CaptchaChallenge(
          id: 'late-owned-id',
          bytes: tinyPng(),
          createdAt: DateTime.now(),
          domain: CaptchaChallengeDomain.unifiedAuth,
          accountRevision: 1,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(invalidatedIds, ['late-owned-id']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late challenge resolved after timeout is invalidated by its id',
    (tester) async {
      final completer = Completer<CaptchaChallenge>();
      final invalidatedIds = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () {},
              loadSavedCredentials: () async => ('', ''),
              sessionPreflight: () async => false,
              challengeLoader: ({cancelToken}) => completer.future,
              challengeInvalidator: (id) => invalidatedIds.add(id),
            ),
          ),
        ),
      );
      await tester.pump();

      // Preparation budget expires before the challenge is armed.
      await tester.pump(const Duration(seconds: 20));

      completer.complete(
        CaptchaChallenge(
          id: 'late-timeout-id',
          bytes: tinyPng(),
          createdAt: DateTime.now(),
          domain: CaptchaChallengeDomain.unifiedAuth,
          accountRevision: 1,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(invalidatedIds, ['late-timeout-id']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing page invalidates only its own challenge id', (
    tester,
  ) async {
    final invalidatedIds = <String>[];
    final challenge = CaptchaChallenge(
      id: 'challenge-owned-123',
      bytes: tinyPng(),
      createdAt: DateTime.now(),
      domain: CaptchaChallengeDomain.unifiedAuth,
      accountRevision: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            challengeLoader: ({cancelToken}) async => challenge,
            challengeInvalidator: (id) => invalidatedIds.add(id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(invalidatedIds, isEmpty);

    // Dispose
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(invalidatedIds, ['challenge-owned-123']);
  });

  testWidgets('refresh during submit does not cause mismatch or race', (
    tester,
  ) async {
    var loaderCalls = 0;
    var submitCalls = 0;
    final submitCompleter = Completer<UnifiedAuthLoginResult>();

    final challenge = CaptchaChallenge(
      id: 'challenge-stable',
      bytes: tinyPng(),
      createdAt: DateTime.now(),
      domain: CaptchaChallengeDomain.unifiedAuth,
      accountRevision: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('account', 'password'),
            saveCredentials: (_, _) async {},
            clearCredentials: () async {},
            enableAutoLogin: (_) async => AuthRecoveryEnableResult.enabled,
            recordAutoLoginSuccess: () async {},
            disableAutoLogin: () async {},
            sessionPreflight: () async => false,
            challengeLoader: ({cancelToken}) async {
              loaderCalls++;
              return challenge;
            },
            challengeSubmitter:
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
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loaderCalls, 1);

    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.text('登录'));
    await tester.pump(); // Submit started, _loading is true

    expect(submitCalls, 1);

    // Try tapping refresh container during submission
    await tester.tap(find.byType(Image));
    await tester.pump();

    // Try tapping submit button during submission
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    // Verify neither loader nor submitter received additional calls
    expect(loaderCalls, 1);
    expect(submitCalls, 1);

    // Complete submission
    submitCompleter.complete(UnifiedAuthLoginSuccess());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'staleOperation failure refreshes captcha and shows plain message',
    (tester) async {
      var loaderCalls = 0;
      final challengeA = CaptchaChallenge(
        id: 'challenge-stale-A',
        bytes: tinyPng(),
        createdAt: DateTime.now(),
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 1,
      );
      final challengeB = CaptchaChallenge(
        id: 'challenge-fresh-B',
        bytes: tinyPng(),
        createdAt: DateTime.now(),
        domain: CaptchaChallengeDomain.unifiedAuth,
        accountRevision: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () {},
              loadSavedCredentials: () async => ('account', 'password'),
              sessionPreflight: () async => false,
              challengeLoader: ({cancelToken}) async {
                loaderCalls++;
                return loaderCalls == 1 ? challengeA : challengeB;
              },
              challengeSubmitter:
                  ({
                    required challengeId,
                    required username,
                    required password,
                    required captcha,
                    cancelToken,
                  }) async {
                    return UnifiedAuthLoginFailure(
                      '验证码已失效，请刷新后重试',
                      kind: AuthFailureKind.staleOperation,
                    );
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loaderCalls, 1);

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      // Plain Chinese message is shown
      expect(find.text('验证码已失效，请刷新后重试'), findsOneWidget);
      // Captcha text field is cleared
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller?.text,
        isEmpty,
      );
      // Automatically refreshed to challenge B
      expect(loaderCalls, 2);
      // Error message remains visible after refresh
      expect(find.text('验证码已失效，请刷新后重试'), findsOneWidget);
    },
  );

  testWidgets('shows validation error when fields are empty', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () async => tinyPng(),
            loginHandler: (_, _, _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('登录'));
    await tester.pump();

    expect(find.text('请填写账号、密码和验证码'), findsOneWidget);
  });

  testWidgets(
    'production default service path carries challenge id without fallback',
    (tester) async {
      final adapter = MockHttpClientAdapter()
        ..register(
          'GET',
          '/cas/login',
          (options) async => ResponseBody.fromString(
            '''
<html>
  <form id="fm1" action="/cas/login">
    <input type="hidden" name="lt" value="LT-default-1" />
    <input type="hidden" name="execution" value="e1s1" />
  </form>
</html>''',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            },
          ),
        )
        ..register(
          'GET',
          '/cas/captcha.html',
          (options) async => ResponseBody.fromBytes(
            tinyPng(),
            200,
            headers: {
              Headers.contentTypeHeader: ['image/png'],
            },
          ),
        )
        ..register(
          'POST',
          '/cas/login',
          (options) async => ResponseBody.fromString(
            '<html><span id="msg">账号或密码错误</span></html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html; charset=utf-8'],
            },
          ),
        );

      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      var loginSucceeded = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () => loginSucceeded = true,
              loadSavedCredentials: () async => ('default_user', 'secret123'),
              saveCredentials: (_, _) async {},
              sessionPreflight: () async => false,
            ),
          ),
        ),
      );

      // 生产路径 prepare 由真实 service 建立 challenge：可控 pump 直到图片就绪，
      // 不绕过 prepareCaptchaChallenge，也不用无界 pumpAndSettle（加载中 spinner
      // 会持续调度帧）。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byType(Image).evaluate().isNotEmpty) break;
      }

      // 验证码图片由默认 service 加载，且 challenge 已被 arm（带 id）。
      expect(find.byType(Image), findsOneWidget);
      expect(UnifiedAuthService.instance.hasActiveCaptchaChallenge, isTrue);

      // 提交：真实 submitCaptchaChallenge 使用该 challenge id 完成一次往返。
      await tester.enterText(find.byType(TextField).at(2), 'kapt');
      await tester.tap(find.text('登录'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('账号或密码错误').evaluate().isNotEmpty) break;
      }

      // 服务端失败页被真实解析并展示；未走无 id 兼容 fallback。
      expect(find.text('账号或密码错误'), findsOneWidget);
      expect(loginSucceeded, isFalse);
      expect(adapter.requestLog, contains('POST /cas/login'));
    },
  );

  // ── 记住账号并自动登录（cas 域） ──────────────────────────────────────

  CaptchaChallenge casChallenge(String id) => CaptchaChallenge(
    id: id,
    bytes: tinyPng(),
    createdAt: DateTime.now(),
    domain: CaptchaChallengeDomain.unifiedAuth,
    accountRevision: 1,
  );

  Widget buildSubmitSubject({
    required VoidCallback onLoginSuccess,
    LoginCredentialSaver? saveCredentials,
    LoginCredentialClearer? clearCredentials,
    LoginAutoLoginEnabler? enableAutoLogin,
    LoginAutoLoginSuccessRecorder? recordAutoLoginSuccess,
    LoginAutoLoginDisabler? disableAutoLogin,
    UnifiedAuthChallengeSubmitHandler? challengeSubmitter,
    bool useRealAutoLoginHooks = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: UnifiedAuthLoginWidget(
          onLoginSuccess: onLoginSuccess,
          loadSavedCredentials: () async => ('1234567890', 'cas-password'),
          saveCredentials: saveCredentials ?? (_, _) async {},
          clearCredentials: clearCredentials ?? () async {},
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
          sessionPreflight: () async => false,
          challengeLoader: ({cancelToken}) async =>
              casChallenge('challenge-remember'),
          challengeSubmitter:
              challengeSubmitter ??
              ({
                required challengeId,
                required username,
                required password,
                required captcha,
                cancelToken,
              }) async => UnifiedAuthLoginSuccess(),
        ),
      ),
    );
  }

  testWidgets(
    'remember-account defaults to checked and saves credentials + enables cas recovery',
    (tester) async {
      final saved = <(String, String)>[];
      String? enabledAccount;
      var recordSuccessCalls = 0;
      var clearCalls = 0;
      var disableCalls = 0;
      var loginSucceeded = false;

      await tester.pumpWidget(
        buildSubmitSubject(
          onLoginSuccess: () => loginSucceeded = true,
          saveCredentials: (username, password) async =>
              saved.add((username, password)),
          clearCredentials: () async => clearCalls++,
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
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(saved, [('1234567890', 'cas-password')]);
      expect(enabledAccount, '1234567890');
      expect(recordSuccessCalls, 1);
      expect(clearCalls, 0);
      expect(disableCalls, 0);
    },
  );

  testWidgets(
    'unchecking remember-account clears credentials and disables cas recovery',
    (tester) async {
      final saved = <(String, String)>[];
      String? enabledAccount;
      var recordSuccessCalls = 0;
      var clearCalls = 0;
      var disableCalls = 0;
      var loginSucceeded = false;

      await tester.pumpWidget(
        buildSubmitSubject(
          onLoginSuccess: () => loginSucceeded = true,
          saveCredentials: (username, password) async =>
              saved.add((username, password)),
          clearCredentials: () async => clearCalls++,
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
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(saved, isEmpty);
      expect(enabledAccount, isNull);
      expect(recordSuccessCalls, 0);
      expect(clearCalls, 1);
      expect(disableCalls, 1);
    },
  );

  testWidgets('enable throwing still completes cas login success', (
    tester,
  ) async {
    var loginSucceeded = false;
    var recordSuccessCalls = 0;

    await tester.pumpWidget(
      buildSubmitSubject(
        onLoginSuccess: () => loginSucceeded = true,
        enableAutoLogin: (_) async => throw StateError('coordinator down'),
        recordAutoLoginSuccess: () async => recordSuccessCalls++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(2), 'abcd');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(loginSucceeded, isTrue);
    expect(recordSuccessCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'non-enabled enable result still completes cas login without recording success',
    (tester) async {
      var loginSucceeded = false;
      var recordSuccessCalls = 0;

      await tester.pumpWidget(
        buildSubmitSubject(
          onLoginSuccess: () => loginSucceeded = true,
          enableAutoLogin: (_) async =>
              AuthRecoveryEnableResult.accountMismatch,
          recordAutoLoginSuccess: () async => recordSuccessCalls++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(recordSuccessCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'loginHandler success path also honors the remember-account checkbox',
    (tester) async {
      var saveCalls = 0;
      String? enabledAccount;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedAuthLoginWidget(
              onLoginSuccess: () {},
              loadSavedCredentials: () async => ('1234567890', 'cas-password'),
              saveCredentials: (_, _) async => saveCalls++,
              clearCredentials: () async {},
              enableAutoLogin: (account) async {
                enabledAccount = account;
                return AuthRecoveryEnableResult.enabled;
              },
              recordAutoLoginSuccess: () async {},
              disableAutoLogin: () async {},
              sessionPreflight: () async => false,
              captchaLoader: () async => tinyPng(),
              loginHandler: (_, _, _) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(saveCalls, 1);
      expect(enabledAccount, '1234567890');
    },
  );

  testWidgets(
    'production default hooks enable cas recovery through the real coordinator',
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
        buildSubmitSubject(
          onLoginSuccess: () => loginSucceeded = true,
          useRealAutoLoginHooks: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(2), 'abcd');
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(loginSucceeded, isTrue);
      expect(domains, [AuthRecoveryDomain.cas]);
      expect(tester.takeException(), isNull);
    },
  );

  // ── 凭据分离与 UI 呈现 ─────────────────────────────────────────────

  testWidgets('password hint keeps unified auth credential distinct', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () async => tinyPng(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('一卡通账号'), findsOneWidget);
    expect(find.text('一卡通密码'), findsOneWidget);
    expect(find.text('教务系统密码'), findsNothing);
  });

  testWidgets('validation failure renders the inline error banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () async => tinyPng(),
            loginHandler: (_, _, _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.error_outline), findsNothing);

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.text('请填写账号、密码和验证码'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captcha block exposes a labeled refresh button', (tester) async {
    final handle = tester.ensureSemantics();
    var captchaLoads = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () async {
              captchaLoads += 1;
              return tinyPng();
            },
          ),
        ),
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
    expect(captchaLoads, 2);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('captcha refresh exposes no tap action while loading', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final pending = Completer<Uint8List>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () => pending.future,
          ),
        ),
      ),
    );
    // 首屏仍在「正在准备验证码」状态，进度动画不会停止，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump();

    // 加载中保留进度提示（帮助行只保留这一条文案）。
    expect(find.text('正在准备验证码...'), findsOneWidget);
    expect(find.text('可手动输入，点击图片可换一张'), findsNothing);

    final loadingNode = find.semantics.byLabel('刷新验证码');
    expect(loadingNode.evaluate(), hasLength(1));
    expect(
      loadingNode.evaluate().single.getSemanticsData().hasAction(
        SemanticsAction.tap,
      ),
      isFalse,
    );

    // 收尾：完成挂起的验证码加载，退出加载态并避免遗留超时计时器。
    pending.complete(tinyPng());
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
    final pending = Completer<Uint8List>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnifiedAuthLoginWidget(
            onLoginSuccess: () {},
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () => pending.future,
          ),
        ),
      ),
    );
    // 首屏仍在「正在准备验证码」状态，进度动画不会停止，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump();

    expect(find.text('正在准备验证码...'), findsOneWidget);

    pending.complete(tinyPng());
    await tester.pumpAndSettle();

    // 就绪后帮助行整体隐藏：冗余提示与准备中文案都不再渲染。
    expect(find.text('正在准备验证码...'), findsNothing);
    expect(find.text('可手动输入，点击图片可换一张'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
