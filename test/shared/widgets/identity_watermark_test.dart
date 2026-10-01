import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/shared/widgets/identity_watermark.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    List<String> lines, {
    Brightness brightness = Brightness.light,
    Size size = const Size(360, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(child: IdentityWatermark(lines: lines)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Finder paintFinder() => find.descendant(
    of: find.byType(IdentityWatermark),
    matching: find.byType(CustomPaint),
  );

  testWidgets('empty lines render nothing', (tester) async {
    await pump(tester, const []);
    expect(paintFinder(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paints inside a RepaintBoundary without exceptions', (
    tester,
  ) async {
    await pump(tester, const ['2025001', '20250001']);
    expect(paintFinder(), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(IdentityWatermark),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('is static: no scheduled frames after the first pump', (
    tester,
  ) async {
    await pump(tester, const ['2025001']);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('dark theme lays out', (tester) async {
    await pump(tester, const [
      '2025001',
      '20250001',
    ], brightness: Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updating lines rebuilds the painter', (tester) async {
    await pump(tester, const ['2025001']);
    final first = tester.widget<CustomPaint>(paintFinder()).painter;
    await pump(tester, const ['2025001', '20250001']);
    final second = tester.widget<CustomPaint>(paintFinder()).painter;
    expect(identical(first, second), isFalse);
    expect(tester.takeException(), isNull);
  });
}
