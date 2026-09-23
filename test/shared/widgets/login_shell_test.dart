import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/shared/widgets/login_shell.dart';
import 'package:jxu_campus_hub/shared/widgets/login_widget.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_login_widget.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('provides material ancestor for embedded text fields', (
    tester,
  ) async {
    await pumpPage(
      tester,
      const LoginShell(
        title: '登录',
        description: '说明',
        child: Padding(padding: EdgeInsets.all(24), child: TextField()),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('badge chip differentiates academic and unified auth domains', (
    tester,
  ) async {
    await pumpPage(
      tester,
      const LoginShell(
        title: '登录教务系统',
        description: '说明',
        badgeText: '教务系统',
        child: SizedBox.shrink(),
      ),
    );

    expect(find.byIcon(Icons.school_outlined), findsOneWidget);
    expect(find.text('教务系统'), findsOneWidget);

    await pumpPage(
      tester,
      const LoginShell(
        title: '登录统一认证',
        description: '说明',
        badgeText: '统一认证',
        child: SizedBox.shrink(),
      ),
    );

    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    expect(find.text('统一认证'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  Future<void> pumpAtNarrowLargeText(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: Scaffold(body: child),
        ),
      ),
    );
    // 固定时长 pump：表单内的加载指示与图片解码在 fake-async 下不适合
    // 无界 pumpAndSettle。
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'unified auth form fits 360px screen at 1.5x text without overflow',
    (tester) async {
      await pumpAtNarrowLargeText(
        tester,
        LoginShell(
          title: '登录统一认证',
          description: '登录后可进入一卡通、服务大厅等服务',
          badgeText: '统一认证',
          child: UnifiedAuthLoginWidget(
            title: '登录统一认证',
            description: '登录后可进入一卡通、服务大厅等服务',
            showHeader: false,
            padding: EdgeInsets.zero,
            loadSavedCredentials: () async => ('', ''),
            sessionPreflight: () async => false,
            captchaLoader: () async => tinyPng(),
            onLoginSuccess: () {},
          ),
        ),
      );

      expect(find.text('登录统一认证'), findsOneWidget);
      expect(find.text('一卡通账号'), findsOneWidget);
      expect(find.text('一卡通密码'), findsOneWidget);
      expect(find.text('记住账号并自动登录'), findsOneWidget);
      expect(find.text('自动登录并自动刷新数据；不勾选则不保存密码'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('academic form fits 360px screen at 1.5x text without overflow', (
    tester,
  ) async {
    await pumpAtNarrowLargeText(
      tester,
      LoginShell(
        title: '登录教务系统',
        description: '登录后可查看课表、成绩与教务服务',
        badgeText: '教务系统',
        child: LoginWidget(
          showHeader: false,
          padding: EdgeInsets.zero,
          onLoginSuccess: () {},
          directReachabilityChecker: () async => true,
          webVpnReachabilityChecker: () async => false,
          gatewaySessionEnsurer: () async => false,
          captchaLoader: () async => tinyPng(),
          loginHandler: (_, _, _) async => LoginFailure('unused'),
          // 必须返回非空凭据：null 会触发真实 CredentialStore 回退，
          // 在 fake-async 区永远不会完成。
          credentialLoader: () async => ('20250001', 'test-pw'),
          modeSetter: (_) {},
        ),
      ),
    );

    expect(find.text('登录教务系统'), findsWidgets);
    expect(find.widgetWithText(FilledButton, '登录教务系统'), findsOneWidget);
    expect(find.text('教务系统密码'), findsOneWidget);
    expect(find.text('记住账号并自动登录'), findsOneWidget);
    expect(find.text('自动登录并自动刷新数据；不勾选则不保存密码'), findsOneWidget);
    // 加载已完成（无残留 spinner），布局无溢出。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
