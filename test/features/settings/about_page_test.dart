import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/settings/about_page.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  void mockClipboard(WidgetTester tester, {required bool fail}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && fail) {
          throw PlatformException(code: 'clipboard');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  testWidgets('关于页提供复制登录诊断日志入口并复制成功提示', (tester) async {
    mockClipboard(tester, fail: false);
    await pumpPage(tester, const AboutPage());

    expect(find.text('复制登录诊断日志'), findsOneWidget);
    expect(find.text('已脱敏，不含密码与验证码'), findsOneWidget);

    await tester.tap(find.text('复制登录诊断日志'));
    await tester.pumpAndSettle();

    expect(find.text('登录诊断日志已复制'), findsOneWidget);
  });

  testWidgets('剪贴板失败时提示复制失败', (tester) async {
    mockClipboard(tester, fail: true);
    await pumpPage(tester, const AboutPage());

    await tester.tap(find.text('复制登录诊断日志'));
    await tester.pumpAndSettle();

    expect(find.text('复制失败'), findsOneWidget);
  });
}
