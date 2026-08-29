import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_button.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  Future<void> pumpButton(
    WidgetTester tester, {
    VoidCallback? onPressed,
    bool blurred = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassButton.text(
              onPressed: onPressed,
              text: '次操作',
              blurred: blurred,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('玻璃开启时默认创建 BackdropFilter（真实模糊）', (tester) async {
    await pumpButton(tester, onPressed: () {});

    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('blurred=false 跳过真实模糊（密集按钮组省 GPU）', (tester) async {
    await pumpButton(tester, onPressed: () {}, blurred: false);

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('全局玻璃关闭后降级为实色面且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpButton(tester, onPressed: () {});

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('模糊强度拉到 0 时不创建 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setBlurSigma(0);
    await pumpButton(tester, onPressed: () {});

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('点击回调正常触发', (tester) async {
    var tapped = false;
    await pumpButton(tester, onPressed: () => tapped = true);

    await tester.tap(find.text('次操作'));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });
}
