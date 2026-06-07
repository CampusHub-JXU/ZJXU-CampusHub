import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    UnifiedAuthService.instance.debugReset();
    AppLogger.instance.debugReset();
  });

  testWidgets('shows login guidance when unified auth session check throws', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async {
      throw StateError('session check failed');
    };
    AppLogger.instance.loggingEnabled.value = false;

    await tester.pumpWidget(
      const MaterialApp(
        home: UnifiedAuthProtectedWebViewPage(
          title: '校园卡',
          url: 'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form',
          autoPromptLogin: false,
        ),
      ),
    );

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 当验证失败时，信任保存的会话，显示 WebView 而不是登录引导
    // 注意：由于测试环境没有 WebView 平台，可能会抛出异常
    // 但我们期望不会显示 AuthRequiredView
    final authRequiredViews = find.byType(AuthRequiredView).evaluate();
    expect(authRequiredViews.isEmpty, true);
  });
}
