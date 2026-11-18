import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/shared/widgets/app_search_field.dart';

/// Focused coverage for the optional [AppSearchField.focusNode] plumbing added
/// for Issue #43 (search tile ring must follow the real TextField focus node).
void main() {
  testWidgets('forwards a caller-owned FocusNode to the inner TextField', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode(debugLabel: 'test');
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSearchField(
            controller: controller,
            focusNode: focusNode,
            hintText: '搜索',
            onChanged: (_) {},
            onClear: controller.clear,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode,
      focusNode,
    );
    expect(focusNode.hasFocus, isFalse);

    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    // The node the caller observes is the one the widget focuses.
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    focusNode.unfocus();
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
  });

  testWidgets('compact form also forwards the caller-owned FocusNode', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: AppSearchField(
              controller: controller,
              focusNode: focusNode,
              hintText: '搜索',
              compact: true,
              onChanged: (_) {},
              onClear: controller.clear,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode,
      focusNode,
    );
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('stays backward compatible when no FocusNode is provided', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final changes = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSearchField(
            controller: controller,
            hintText: '搜索',
            onChanged: changes.add,
            onClear: controller.clear,
          ),
        ),
      ),
    );
    await tester.pump();

    // No caller node: the TextField manages its own focus internally.
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode, isNull);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(changes, contains('abc'));
    expect(find.byTooltip('清除搜索'), findsOneWidget);
  });
}
