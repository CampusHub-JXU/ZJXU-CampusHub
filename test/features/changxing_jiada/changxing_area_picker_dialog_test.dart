import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/changxing_jiada/changxing_area_picker_dialog.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_model.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';

class _FakeAreaService implements ChangxingJiadaService {
  @override
  Future<List<ChangxingAreaNode>> fetchAreaChildren(int parentId) async => [
    ChangxingAreaNode(
      id: parentId * 10 + 1,
      areaName: '区域${parentId * 10 + 1}',
    ),
    ChangxingAreaNode(
      id: parentId * 10 + 2,
      areaName: '区域${parentId * 10 + 2}',
    ),
  ];

  @override
  Future<List<ChangxingAreaNode>> fetchAreaParents(int areaId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showChangxingAreaPickerDialog(
                context: context,
                service: _FakeAreaService(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dialog content is not double-inset on a 360x640 phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openDialog(tester);

    expect(tester.takeException(), isNull);
    final dialogRect = tester.getRect(find.byType(AlertDialog));
    expect(dialogRect.width, greaterThan(300));
    final dropdownRect = tester.getRect(
      find.byType(AppDropdown<ChangxingAreaNode>).first,
    );
    expect(dropdownRect.width, greaterThan(250));
  });

  testWidgets('dialog content scrolls instead of overflowing in landscape', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openDialog(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('back with a dropdown menu open closes only the menu', (
    tester,
  ) async {
    await _openDialog(tester);
    await tester.tap(find.byType(AppDropdown<ChangxingAreaNode>).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-dropdown-menu')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-dropdown-menu')), findsNothing);
    expect(find.text('选择生源地'), findsOneWidget);
  });
}
