import 'dart:ui' show Tristate;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_reminder_settings.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';
import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';
import 'package:jxu_campus_hub/features/welcome/welcome_page.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    PageTransitionActivity.instance.debugReset();
    await resetTestEnvironment();
  });

  /// 顶部搜索框的 TextField 内部带横向 Scrollable，裸 scrollUntilVisible
  /// 会因匹配多个滚动容器而失败；这里显式锁定页面主 ListView（树序第一个
  /// Scrollable，TextField 的 Scrollable 是其子孙，遍历在其后）。
  Future<void> scrollSettingsTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }

  testWidgets('显示外观设置链接和学期设置', (tester) async {
    await pumpPage(tester, const SettingsPage());

    expect(find.text('主题与材质'), findsOneWidget);
    expect(find.text('首页个性化'), findsOneWidget);
    expect(find.text('外观与个性化'), findsNothing);
    expect(find.text('主题与色彩'), findsNothing);

    await scrollSettingsTo(tester, find.text('检查更新'));
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('「更新下载线路」默认自动，选择后持久化', (tester) async {
    await pumpPage(tester, const SettingsPage());
    // 该下拉在屏外、行文本可能被遮：先对行做滚动定位，再对组件本身 ensureVisible。
    await scrollSettingsTo(
      tester,
      find.byKey(const Key('update_route_dropdown')),
    );
    await tester.ensureVisible(find.byKey(const Key('update_route_dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('更新下载线路'), findsOneWidget);
    expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.auto);

    await tester.tap(find.byKey(const Key('update_route_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EdgeOne').last);
    await tester.pumpAndSettle();

    expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.edgeone);
  });

  testWidgets('无小节标题分隔，关键入口齐备', (tester) async {
    await pumpPage(tester, const SettingsPage());

    // 无小节标题：保留顶部搜索框与干净分组间距。
    expect(find.byType(PlainSectionHeader), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('主题与材质'), findsOneWidget);
    expect(find.text('首页个性化'), findsOneWidget);

    await scrollSettingsTo(tester, find.text('写入系统日历'));
    expect(find.text('开学日'), findsOneWidget);
    expect(find.text('写入系统日历'), findsOneWidget);
    expect(find.text('桌面组件与后台'), findsOneWidget);

    await scrollSettingsTo(tester, find.text('AI 模型与接口'));
    expect(find.text('AI 模型与接口'), findsOneWidget);
    // 旧分组名已并入新分组，不再存在。
    expect(find.text('课表与后台'), findsNothing);
    expect(find.text('其他'), findsNothing);
    // 账号入口只在「我的」页，设置页不重复承载。
    expect(find.text('教务系统'), findsNothing);
    expect(find.text('统一认证'), findsNothing);

    await scrollSettingsTo(tester, find.text('关于与诊断'));
    expect(find.text('关于与诊断'), findsOneWidget);
  });

  testWidgets('顶部搜索框支持过滤设置项并可清空恢复', (tester) async {
    await pumpPage(tester, const SettingsPage());

    await tester.enterText(find.byType(TextField), '缓存');
    await tester.pumpAndSettle();

    expect(find.text('清除离线缓存'), findsOneWidget);
    expect(find.text('主题与材质'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(find.text('主题与材质'), findsOneWidget);
  });

  testWidgets('搜索可命中子页面设置项并显示路径', (tester) async {
    await pumpPage(tester, const SettingsPage());

    // 「主题与材质 › 显示与排版」下的纯黑模式。
    await tester.enterText(find.byType(TextField), '纯黑模式');
    await tester.pumpAndSettle();
    expect(find.text('纯黑模式'), findsWidgets);
    expect(find.text('主题与材质 › 显示与排版'), findsOneWidget);

    // 「首页个性化 › 首页内容」下的校徽水印。
    await tester.enterText(find.byType(TextField), '校徽水印');
    await tester.pumpAndSettle();
    expect(find.text('校徽水印'), findsWidgets);
    expect(find.text('首页个性化 › 首页内容'), findsOneWidget);
  });

  testWidgets('子页面设置项支持分词与无匹配空态', (tester) async {
    await pumpPage(tester, const SettingsPage());

    // 空格分词：两个词命中同一子项。
    await tester.enterText(find.byType(TextField), '壁纸 缩放');
    await tester.pumpAndSettle();
    expect(find.text('壁纸'), findsOneWidget);
    expect(find.text('首页个性化 › 壁纸'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '不存在的设置项');
    await tester.pumpAndSettle();
    expect(find.text('未找到相关设置'), findsOneWidget);
  });

  testWidgets('学期磁贴展示开学日与当前学期', (tester) async {
    await pumpPage(tester, const SettingsPage());

    // 开学日与当前学期合并为同一 Bento 磁贴：大号日期 + 精简学期串。
    await scrollSettingsTo(tester, find.text('开学日'));
    expect(find.text('开学日'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'\d{2}-\d{2} · 第[一二]学期')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('真实 push 转场期间学期异步结果延后到转场结束', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkThemeFor(AppColors.primary)
            .copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(),
                    ),
                  );
                },
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );

    final transitions = PageTransitionActivity.instance;
    transitions.debugMaxHold = const Duration(minutes: 1);
    transitions.acquire();
    await tester.tap(find.text('打开设置'));
    await tester.pump();
    await tester.pump();
    expect(find.text('开学日'), findsOneWidget);

    final route = ModalRoute.of(tester.element(find.text('开学日')))!;
    expect(route.animation!.isAnimating, isTrue);
    expect(transitions.isBusy, isTrue);

    try {
      // Finish the actual route animation without advancing fake time through
      // the transition activity watchdog.
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(route.animation!.isAnimating, isFalse);
      expect(transitions.isBusy, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      transitions.release();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    } finally {
      if (transitions.isBusy) transitions.release();
    }
  });

  testWidgets('设置页在 push 转场中被 pop 后异步回调安全结束', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkThemeFor(AppColors.primary)
            .copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(),
                    ),
                  );
                },
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );

    final transitions = PageTransitionActivity.instance;
    transitions.debugMaxHold = const Duration(minutes: 1);
    transitions.acquire();
    try {
      await tester.tap(find.text('打开设置'));
      await tester.pump();
      await tester.pump();
      expect(find.text('开学日'), findsOneWidget);
      expect(transitions.isBusy, isTrue);

      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pumpAndSettle();

      transitions.release();
      await tester.pump();
      expect(find.text('打开设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      if (transitions.isBusy) transitions.release();
    }
  });

  testWidgets('课前提醒连续变更在转场中合并，空闲后显示最新值', (tester) async {
    await pumpPage(tester, const SettingsPage());
    await tester.pumpAndSettle();
    await scrollSettingsTo(tester, find.text('课前提醒'));

    final transitions = PageTransitionActivity.instance;
    transitions.debugMaxHold = const Duration(minutes: 1);
    transitions.acquire();
    try {
      await CalendarReminderSettings.instance.setReminderMinutes(5);
      await CalendarReminderSettings.instance.setReminderMinutes(30);
      await tester.pump();

      expect(CalendarReminderSettings.instance.reminderMinutes, 30);
      expect(
        tester
            .widget<AppDropdown<int>>(
              find.byKey(const Key('calendar_reminder_dropdown')),
            )
            .value,
        20,
      );

      transitions.release();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppDropdown<int>>(
              find.byKey(const Key('calendar_reminder_dropdown')),
            )
            .value,
        30,
      );
    } finally {
      if (transitions.isBusy) transitions.release();
    }
  });

  testWidgets('学期分组不再提供手动年级，保留开学日与当前学期磁贴', (tester) async {
    await pumpPage(tester, const SettingsPage());

    // 手动「年级」下拉已移除，学期分组只剩自动识别与日期相关条目。
    await scrollSettingsTo(tester, find.text('开学日'));
    expect(find.text('年级'), findsNothing);
    expect(find.text('当前学期'), findsNothing);
    expect(find.text('开学日'), findsOneWidget);
    expect(find.textContaining(RegExp(r'· 第[一二]学期')), findsOneWidget);
  });

  /// 文案节点可能不带动作/标记，向上找到承载该语义的行节点。
  SemanticsNode? ancestorWith(
    WidgetTester tester,
    Finder finder,
    bool Function(SemanticsData data) predicate,
  ) {
    SemanticsNode? node = tester.getSemantics(finder);
    while (node != null && !predicate(node.getSemanticsData())) {
      node = node.parent;
    }
    return node;
  }

  testWidgets('设置行暴露按钮语义与点击动作', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPage(tester, const SettingsPage());

    final tapNode = ancestorWith(
      tester,
      find.text('主题与材质'),
      (data) => data.hasAction(SemanticsAction.tap),
    );
    expect(tapNode, isNotNull, reason: '导航设置行应暴露点击动作');

    final buttonNode = ancestorWith(
      tester,
      find.text('主题与材质'),
      (data) => data.flagsCollection.isButton,
    );
    expect(buttonNode, isNotNull, reason: '可点击设置行应标记为按钮');

    handle.dispose();
  });

  testWidgets('写入系统日历开关磁贴暴露开关状态语义', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPage(tester, const SettingsPage());

    await scrollSettingsTo(tester, find.text('写入系统日历'));

    final toggleNode = ancestorWith(
      tester,
      find.text('写入系统日历'),
      (data) => data.flagsCollection.isToggled != Tristate.none,
    );
    expect(toggleNode, isNotNull, reason: '开关磁贴应暴露开/关状态');

    final tapNode = ancestorWith(
      tester,
      find.text('写入系统日历'),
      (data) => data.hasAction(SemanticsAction.tap),
    );
    expect(tapNode, isNotNull, reason: '点磁贴即切换，应暴露点击动作');

    handle.dispose();
  });

  testWidgets('宽屏下设置内容列限宽居中', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpPage(tester, const SettingsPage());

    // 内容列限宽 640，列表左右各留 kPlainListGutter(20) 内边距。
    expect(
      tester.getSize(find.byType(PlainListGroup).first).width,
      640 - 2 * kPlainListGutter,
    );
  });

  testWidgets('清除离线缓存需二次确认，取消不执行', (tester) async {
    await pumpPage(tester, const SettingsPage());

    await scrollSettingsTo(tester, find.text('清除离线缓存'));
    // 学期分组移除「年级」行后内容变短，滚动停位更靠近视口边缘；
    // 显式 ensureVisible + settle 保证行完全可点击（内容与语义不变）。
    await tester.ensureVisible(find.text('清除离线缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除离线缓存'));
    await tester.pumpAndSettle();

    expect(find.text('将清除目录等临时缓存，不影响登录状态、课表缓存与个性化设置。'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '清除'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('离线缓存已清除'), findsNothing);
  });

  testWidgets('360 宽 / 2 倍字号下设置页不溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpPage(tester, const SettingsPage());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await scrollSettingsTo(tester, find.text('关于与诊断'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页不再直接暴露调试日志分段（已迁往关于页隐藏入口）', (tester) async {
    await pumpPage(tester, const SettingsPage());
    await scrollSettingsTo(tester, find.text('关于与诊断'));

    expect(find.text('调试日志'), findsNothing);
    expect(find.text('最低日志级别'), findsNothing);
    expect(find.text('通知测试'), findsNothing);
  });

  testWidgets('设置页常驻「重放新手引导」，点按弹出欢迎向导', (tester) async {
    // 重放走注册路由（routes.dart 组合层），测试侧需最小 GoRouter
    // 提供 'welcome' 目标；动作落点行为不在本用例范围。
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          name: 'settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          path: '/welcome',
          name: 'welcome',
          builder: (context, state) => const WelcomePage(),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.darkThemeFor(AppColors.primary)
            .copyWith(platform: TargetPlatform.android),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await scrollSettingsTo(tester, find.text('重放新手引导'));
    await tester.ensureVisible(find.text('重放新手引导'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重放新手引导'));
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.text('连接校园身份'), findsOneWidget);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomePage), findsNothing);
  });
}
