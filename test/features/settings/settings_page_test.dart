import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/settings/settings_page.dart';

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
}
