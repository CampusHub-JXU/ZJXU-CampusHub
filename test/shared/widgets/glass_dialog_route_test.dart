import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_dialog_route.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  group('showGlassDialog', () {
    Future<void> openDialog(
      WidgetTester tester, {
      required bool glassOn,
    }) async {
      if (!glassOn) {
        await GlassStyleController.instance.setEnabled(false);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showGlassDialog<void>(
                context: context,
                builder: (_) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('玻璃对话框内容'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('玻璃开启时渲染 overlay 模糊表面与内容', (tester) async {
      await openDialog(tester, glassOn: true);

      expect(find.text('玻璃对话框内容'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('玻璃关闭时降级实色且无 BackdropFilter', (tester) async {
      await openDialog(tester, glassOn: false);

      expect(find.text('玻璃对话框内容'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });

  group('showGlassModalBottomSheet', () {
    Future<void> openSheet(WidgetTester tester, {required bool glassOn}) async {
      if (!glassOn) {
        await GlassStyleController.instance.setEnabled(false);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showGlassModalBottomSheet<void>(
                context: context,
                builder: (_) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('玻璃弹层内容'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('玻璃开启时渲染 overlay 模糊表面与内容', (tester) async {
      await openSheet(tester, glassOn: true);

      expect(find.text('玻璃弹层内容'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('玻璃关闭时降级实色且无 BackdropFilter', (tester) async {
      await openSheet(tester, glassOn: false);

      expect(find.text('玻璃弹层内容'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  });
}
