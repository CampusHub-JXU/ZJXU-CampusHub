import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/settings/background_editor_page.dart';

void main() {
  Future<BackgroundEditorResult?> openEditor(
    WidgetTester tester, {
    required Future<void> Function(WidgetTester tester) interact,
  }) async {
    BackgroundEditorResult? result;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                opened = true;
                result = await Navigator.of(context)
                    .push<BackgroundEditorResult>(
                      MaterialPageRoute(
                        builder: (_) => const BackgroundEditorPage(
                          args: BackgroundEditorArgs(imagePath: '/missing.jpg'),
                        ),
                      ),
                    );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    await interact(tester);
    return result;
  }

  testWidgets('确认回传编辑后的变换（与正式状态分离）', (tester) async {
    final result = await openEditor(
      tester,
      interact: (tester) async {
        await tester.drag(
          find.byKey(const ValueKey('background-editor-viewport')),
          const Offset(30, 0),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('确认'));
        await tester.pumpAndSettle();
      },
    );

    expect(result, isNotNull);
    expect(result!.alignment.x, greaterThan(0));
  });

  testWidgets('取消回传 null（不修改正式状态）', (tester) async {
    final result = await openEditor(
      tester,
      interact: (tester) async {
        await tester.tap(find.byTooltip('取消'));
        await tester.pumpAndSettle();
      },
    );

    expect(result, isNull);
  });
}
