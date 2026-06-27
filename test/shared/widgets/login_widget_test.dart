import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/shared/widgets/login_widget.dart';

void main() {
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
          credentialSaver: (_, _) async {},
          modeSetter: modeSetter ?? (_) {},
          unifiedAuthStageBuilder: unifiedAuthStageBuilder,
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
}
