import 'package:flutter/material.dart';
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
  });
}
