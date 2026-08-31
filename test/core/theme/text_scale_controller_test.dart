import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/theme/text_scale_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('caps oversized text scale factor at max threshold', () {
    expect(
      TextScaleController.normalizeScaleFactor(1.5),
      TextScaleController.maxScaleFactor,
    );
  });

  testWidgets('app text scale scope adjusts system text scaling', (
    tester,
  ) async {
    double? scaledFontSize;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppTextScaleScope(
            scaleFactor: 0.8,
            child: Builder(
              builder: (context) {
                scaledFontSize = MediaQuery.textScalerOf(context).scale(10);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    expect(scaledFontSize, closeTo(12.0, 0.001));
  });

  testWidgets(
    'default factor 0.9 no longer passes system scaler through（bug 修复）',
    (tester) async {
      double? scaledFontSize;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: AppTextScaleScope(
              scaleFactor: TextScaleController.defaultScaleFactor,
              child: Builder(
                builder: (context) {
                  scaledFontSize = MediaQuery.textScalerOf(context).scale(10);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      // 1.5（系统）× 0.9（默认因子）= 1.35，不再透传 1.5。
      expect(scaledFontSize, closeTo(13.5, 0.001));
    },
  );

  testWidgets('app text scale scope multiplies system scaler by user factor', (
    tester,
  ) async {
    double? scaledFontSize;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppTextScaleScope(
            scaleFactor: 1.2,
            child: Builder(
              builder: (context) {
                scaledFontSize = MediaQuery.textScalerOf(context).scale(10);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    expect(scaledFontSize, closeTo(15.6, 0.001));
  });

  testWidgets('app text scale scope combines system scale with user factor', (
    tester,
  ) async {
    double? effectiveScaleFactor;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppTextScaleScope(
            scaleFactor: 0.8,
            child: Builder(
              builder: (context) {
                final scaler = MediaQuery.textScalerOf(context);
                effectiveScaleFactor = scaler.scale(14) / 14;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    expect(effectiveScaleFactor, closeTo(1.2, 0.001));
  });
}
