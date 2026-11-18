import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';

void main() {
  group('AppDropdown', () {
    testWidgets('displays selected value label on the button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppDropdown<String>(
                value: 'a',
                items: const [
                  AppDropdownItem(value: 'a', label: 'Alpha'),
                  AppDropdownItem(value: 'b', label: 'Beta'),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    });

    testWidgets('displays hint when value is null', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppDropdown<String>(
                value: null,
                hint: '请选择',
                items: const [AppDropdownItem(value: 'a', label: 'Alpha')],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('请选择'), findsOneWidget);
    });

    testWidgets('shows prefix icon when provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppDropdown<String>(
                value: 'a',
                prefixIcon: Icons.school,
                items: const [AppDropdownItem(value: 'a', label: 'Alpha')],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.school), findsOneWidget);
    });

    testWidgets('updates displayed label when value changes', (tester) async {
      late StateSetter setState;
      var selected = 'a';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, s) {
                  setState = s;
                  return AppDropdown<String>(
                    value: selected,
                    items: const [
                      AppDropdownItem(value: 'a', label: 'Alpha'),
                      AppDropdownItem(value: 'b', label: 'Beta'),
                    ],
                    onChanged: (v) => setState(() => selected = v!),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('Alpha'), findsOneWidget);
      setState(() => selected = 'b');
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('renders the label caption above the trigger', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppDropdown<String>(
                label: '交通方式',
                value: 'a',
                items: const [AppDropdownItem(value: 'a', label: 'Alpha')],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      final captionRect = tester.getRect(find.text('交通方式'));
      final triggerRect = tester.getRect(find.text('Alpha'));
      expect(captionRect.bottom, lessThanOrEqualTo(triggerRect.top));
      // 带 label 时强制撑满宽度。
      final fieldRect = tester.getRect(find.byType(AppDropdown<String>));
      expect(fieldRect.width, greaterThan(400));
    });

    testWidgets('does not open the menu when onChanged is null', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppDropdown<String>(
                value: 'a',
                items: [AppDropdownItem(value: 'a', label: 'Alpha')],
                onChanged: null,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AppDropdown<String>));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('app-dropdown-menu')), findsNothing);
    });

    testWidgets('does not open the menu when items are empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppDropdown<String>(
                value: null,
                hint: '请选择',
                items: const [],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AppDropdown<String>));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('app-dropdown-menu')), findsNothing);
    });

    testWidgets('keeps the popup inside the viewport width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: AppDropdown<String>(
                  value: 'a',
                  items: const [
                    AppDropdownItem(value: 'a', label: 'Alpha'),
                    AppDropdownItem(value: 'b', label: 'Beta'),
                    AppDropdownItem(value: 'c', label: 'Gamma'),
                  ],
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AppDropdown<String>));
      await tester.pumpAndSettle();

      final menuRect = tester.getRect(
        find.byKey(const ValueKey('app-dropdown-menu')),
      );
      expect(menuRect.right, lessThanOrEqualTo(320));
      expect(menuRect.left, greaterThanOrEqualTo(12));
    });

    group('back navigation and keyboard', () {
      Widget host() {
        return MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: Column(
                          children: [
                            const TextField(key: ValueKey('field')),
                            AppDropdown<String>(
                              value: 'a',
                              items: const [
                                AppDropdownItem(value: 'a', label: 'Alpha'),
                                AppDropdownItem(value: 'b', label: 'Beta'),
                              ],
                              onChanged: (_) {},
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        );
      }

      Widget single() {
        return MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppDropdown<String>(
                value: 'a',
                items: const [AppDropdownItem(value: 'a', label: 'Alpha')],
                onChanged: (_) {},
              ),
            ),
          ),
        );
      }

      testWidgets('back closes only the menu and keeps the page', (
        tester,
      ) async {
        await tester.pumpWidget(host());
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();

        await tester.tap(find.byType(AppDropdown<String>));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-dropdown-menu')), findsOneWidget);

        // 第一次返回：只关菜单，页面保留。
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-dropdown-menu')), findsNothing);
        expect(find.byType(AppDropdown<String>), findsOneWidget);

        // 第二次返回：菜单已关闭，正常 pop 页面。
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(AppDropdown<String>), findsNothing);
        expect(find.text('go'), findsOneWidget);
      });

      testWidgets('selecting an item unregisters the pop interception', (
        tester,
      ) async {
        await tester.pumpWidget(host());
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();

        await tester.tap(find.byType(AppDropdown<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Beta'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-dropdown-menu')), findsNothing);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(AppDropdown<String>), findsNothing);
      });

      testWidgets('opening unfocuses a focused text field', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const TextField(key: ValueKey('field')),
                  AppDropdown<String>(
                    value: 'a',
                    items: const [AppDropdownItem(value: 'a', label: 'Alpha')],
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('field')));
        await tester.pump();
        final editable = tester.widget<EditableText>(find.byType(EditableText));
        expect(editable.focusNode.hasFocus, isTrue);

        await tester.tap(find.byType(AppDropdown<String>));
        await tester.pumpAndSettle();

        expect(editable.focusNode.hasFocus, isFalse);
        expect(find.byKey(const ValueKey('app-dropdown-menu')), findsOneWidget);
      });

      testWidgets('defers opening until the keyboard is dismissed', (
        tester,
      ) async {
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(single());
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();

        await tester.tap(find.byType(AppDropdown<String>));
        await tester.pump();
        expect(find.byKey(const ValueKey('app-dropdown-menu')), findsNothing);

        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-dropdown-menu')), findsOneWidget);
      });

      testWidgets('falls back to opening if the keyboard never dismisses', (
        tester,
      ) async {
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(single());
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
        await tester.tap(find.byType(AppDropdown<String>));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-dropdown-menu')), findsOneWidget);
      });
    });
  });
}
