import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/settings/settings_page.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
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

  testWidgets('按 外观/校园/桌面与后台/账户与数据/应用 分组', (tester) async {
    await pumpPage(tester, const SettingsPage());

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('校园'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('账户与数据'), 300);
    expect(find.text('账户与数据'), findsOneWidget);
    // 入口已去重：账户与数据分组不再承载教务/统一认证入口。
    expect(find.text('教务系统'), findsNothing);
    expect(find.text('统一认证'), findsNothing);

    await tester.scrollUntilVisible(find.text('应用'), 300);
    expect(find.text('应用'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('学期卡片展示自动识别的当前学年学期', (tester) async {
    await pumpPage(tester, const SettingsPage());

    await tester.scrollUntilVisible(find.text('当前学年学期'), 300);
    expect(find.text('当前学年学期'), findsOneWidget);

    // 未登录教务时无法在线识别，应回退为日期推算并明确标注来源。
    await tester.pumpAndSettle();
    expect(find.textContaining('按日期推算'), findsOneWidget);
    expect(find.textContaining('学年'), findsWidgets);
  });

  testWidgets('我的年级下拉在自动跟随与手动年级间切换', (tester) async {
    await pumpPage(tester, const SettingsPage());

    await tester.scrollUntilVisible(find.text('我的年级'), 300);
    expect(find.text('我的年级'), findsOneWidget);

    // 默认「自动」；说明文案由行副标题承载，不再使用问号 tooltip。
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('默认跟随学号自动识别，仅用于过滤教务处公告，可能误判'), findsOneWidget);

    // 选择手动年级：写入持久化，按钮文案随选中项切换。
    await tester.tap(find.byType(AppDropdown<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2024级'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('profile_enrollment_year'), 2024);

    // 恢复「自动」：手动值清除。菜单项用弹出层 key 定位，与按钮上的
    // 同名回显文案区分开。
    await tester.tap(find.byType(AppDropdown<int>));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('app-dropdown-menu')),
        matching: find.text('自动'),
      ),
    );
    await tester.pumpAndSettle();

    final prefsAfter = await SharedPreferences.getInstance();
    expect(prefsAfter.getInt('profile_enrollment_year'), isNull);
    expect(find.text('自动'), findsOneWidget);
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

    await tester.scrollUntilVisible(find.text('课表日历同步'), 300);

    final toggleNode = ancestorWith(
      tester,
      find.text('课表日历同步'),
      (data) => data.flagsCollection.isToggled != Tristate.none,
    );
    expect(toggleNode, isNotNull, reason: '开关行应暴露开/关状态');

    final tapNode = ancestorWith(
      tester,
      find.text('课表日历同步'),
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

    // 内容列限宽 640，列表左右各留 16 内边距。
    expect(tester.getSize(find.byType(AppCard).first).width, 608);
  });

  testWidgets('清除离线缓存需二次确认，取消不执行', (tester) async {
    await pumpPage(tester, const SettingsPage());

    await tester.scrollUntilVisible(find.text('清除离线缓存'), 300);
    await tester.tap(find.text('清除离线缓存'));
    await tester.pumpAndSettle();

    expect(find.text('将清除目录等临时缓存，不影响登录状态、课表缓存与个性化设置。'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '清除'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('离线缓存已清除'), findsNothing);
  });
}
