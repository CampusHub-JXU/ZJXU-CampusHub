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
      if (find.byType(AuthRequiredView).evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
