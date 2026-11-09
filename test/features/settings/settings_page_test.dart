import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_reminder_settings.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';
import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';
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

  testWidgets('显示外观设置链接和学期设置', (tester) async {
    await pumpPage(tester, const SettingsPage());

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题与色彩'), findsOneWidget);
    expect(find.text('个性化'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('检查更新'), 300);
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('「更新下载线路」默认自动，选择后持久化', (tester) async {
    await pumpPage(tester, const SettingsPage());
    await tester.scrollUntilVisible(find.text('更新下载线路'), 300);

    expect(find.text('更新下载线路'), findsOneWidget);
    expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.auto);

    await tester.tap(find.byKey(const Key('update_route_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EdgeOne').last);
    await tester.pumpAndSettle();

    expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.edgeone);
  });

  testWidgets('按 外观/学期/课表与后台/其他 分组', (tester) async {
    await pumpPage(tester, const SettingsPage());

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('学期'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('课表与后台'), 300);
    expect(find.text('课表与后台'), findsOneWidget);
    // 账号入口只在「我的」页，设置页不重复承载。
    expect(find.text('教务系统'), findsNothing);
    expect(find.text('统一认证'), findsNothing);

    await tester.scrollUntilVisible(find.text('其他'), 300);
    expect(find.text('其他'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('关于与诊断'), 300);
    expect(find.text('关于与诊断'), findsOneWidget);
  });

  testWidgets('学期分组展示当前学期', (tester) async {
    await pumpPage(tester, const SettingsPage());

    await tester.scrollUntilVisible(find.text('当前学期'), 300);
    expect(find.text('当前学期'), findsOneWidget);

    // 未登录教务时无法在线识别，应回退为日期推算并明确标注来源。
    await tester.pumpAndSettle();
    expect(find.textContaining('按日期推算'), findsOneWidget);
    expect(find.textContaining('学年'), findsWidgets);
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
    expect(find.text('当前学期'), findsOneWidget);

    final route = ModalRoute.of(tester.element(find.text('当前学期')))!;
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
      expect(find.text('按日期推算'), findsNothing);

      transitions.release();
      await tester.pumpAndSettle();
      expect(find.text('按日期推算'), findsOneWidget);
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
      expect(find.text('当前学期'), findsOneWidget);
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
    await tester.scrollUntilVisible(find.text('课前提醒'), 300);

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

  testWidgets('学期分组不再提供手动年级，保留当前学期与开学日', (tester) async {
    await pumpPage(tester, const SettingsPage());

    // 手动「年级」下拉已移除，学期分组只剩自动识别与日期相关条目。
    await tester.scrollUntilVisible(find.text('当前学期'), 300);
    expect(find.text('年级'), findsNothing);
    expect(find.text('当前学期'), findsOneWidget);
    expect(find.text('开学日'), findsOneWidget);
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
      find.text('主题与色彩'),
      (data) => data.hasAction(SemanticsAction.tap),
    );
    expect(tapNode, isNotNull, reason: '导航设置行应暴露点击动作');

    final buttonNode = ancestorWith(
      tester,
      find.text('主题与色彩'),
      (data) => data.flagsCollection.isButton,
    );
    expect(buttonNode, isNotNull, reason: '可点击设置行应标记为按钮');

    handle.dispose();
  });

  testWidgets('课表日历开关行暴露开关状态语义', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPage(tester, const SettingsPage());

    await tester.scrollUntilVisible(find.text('同步到系统日历'), 300);

    final toggleNode = ancestorWith(
      tester,
      find.text('同步到系统日历'),
      (data) => data.flagsCollection.isToggled != Tristate.none,
    );
    expect(toggleNode, isNotNull, reason: '开关行应暴露开/关状态');

    final tapNode = ancestorWith(
      tester,
      find.text('同步到系统日历'),
      (data) => data.hasAction(SemanticsAction.tap),
    );
    expect(tapNode, isNotNull, reason: '点行即切换，应暴露点击动作');

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

    await tester.scrollUntilVisible(find.text('清除离线缓存'), 300);
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

    await tester.scrollUntilVisible(find.text('关于与诊断'), 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
