import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/routes.dart';
import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';

void main() {
  // app 级回归：真实 appRouter（go_router → MaterialPage）push 时必须播
  // 300ms 转场。此测试曾复现「真机瞬切」问题：裸 MaterialPageRoute 正常，
  // 但真实路由配置下 route.animation 被瞬间推满。
  testWidgets('real appRouter push animates over ~300ms', (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.darkThemeFor(AppColors.primary),
        themeMode: ThemeMode.dark,
        routerConfig: appRouter,
      ),
    );
    await tester.pump();
    await tester.pump();

    appRouter.push('/settings');
    await tester.pump(); // 安装新路由
    await tester.pump(); // 构建新页

    ModalRoute<dynamic>? topRoute;
    tester.state<NavigatorState>(find.byType(Navigator).first).popUntil((
      route,
    ) {
      topRoute = route as ModalRoute<dynamic>;
      return true; // 只取栈顶，不真正 pop
    });
    expect(topRoute, isNotNull);
    // ignore: invalid_use_of_protected_member

    await tester.pump(const Duration(milliseconds: 150));
    // ignore: avoid_print
    print(
      'DIAG settings route animation@150ms = ${topRoute!.animation!.value}',
    );
    expect(
      topRoute!.animation!.value,
      allOf(greaterThan(0.1), lessThan(0.9)),
      reason: '150ms 时转场应在中段；为 1.0 说明真实路由链路被瞬切',
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(topRoute!.animation!.value, 1.0);
  });
}
