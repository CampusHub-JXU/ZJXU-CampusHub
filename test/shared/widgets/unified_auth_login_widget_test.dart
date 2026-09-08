import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_login_widget.dart';

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
}
