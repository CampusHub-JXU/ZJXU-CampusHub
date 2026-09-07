import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/settings/settings_page.dart';
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
    expect(find.text('主题与外观'), findsOneWidget);
    expect(find.text('首页个性化'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('检查更新'), 300);
    expect(find.text('检查更新'), findsOneWidget);
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
}
