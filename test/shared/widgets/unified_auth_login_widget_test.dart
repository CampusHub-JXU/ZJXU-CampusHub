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
}
