import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/welcome/welcome_page.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  tearDown(() {
    WelcomeFlow.debugReset();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('宿主页面'))),
      ),
    );
    await tester.pump();
  }

  Future<bool> completedFlag() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(welcomeCompletedPrefsKey) ?? false;
  }

  testWidgets('未完成的用户在 shouldShow 处返回 true', (tester) async {
    expect(await WelcomeFlow.shouldShow(), isTrue);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(welcomeCompletedPrefsKey, true);
    expect(await WelcomeFlow.shouldShow(), isFalse);
  });

  testWidgets('欢迎页四页滑动，翻完写 welcome_completed', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.text('连接校园身份'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);

    // 滑到末页。
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
    }
    expect(find.text('准备好了'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
    expect(find.text('跳过'), findsNothing);

    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(await completedFlag(), isTrue);
  });

  testWidgets('跳过同样写完成标记', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(await completedFlag(), isTrue);
  });

  testWidgets('在途时再次 show 不重复 push', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
  });

  testWidgets('首屏「去登录」先关闭向导再回调', (tester) async {
    await pumpHost(tester);

    var loginCalled = false;
    final context = tester.element(find.text('宿主页面'));
    unawaited(
      WelcomeFlow.show(context, onLoginShortcut: (_) => loginCalled = true),
    );
    await tester.pumpAndSettle();

    expect(find.text('去登录'), findsOneWidget);

    await tester.tap(find.text('去登录'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(loginCalled, isTrue);
    expect(await completedFlag(), isTrue);
  });

  testWidgets('动作页「下一步」继续翻页', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context, onLoginShortcut: (_) {}));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('打开通知提醒'), findsOneWidget);
  });

  testWidgets('系统返回键关闭也写完成标记', (tester) async {
    await pumpHost(tester);

    final context = tester.element(find.text('宿主页面'));
    unawaited(WelcomeFlow.show(context));
    await tester.pumpAndSettle();

    // 与系统返回路径一致：根导航 maybePop。
    await Navigator.of(context).maybePop();
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsNothing);
    expect(await completedFlag(), isTrue);
  });
}
