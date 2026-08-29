import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_score_palette.dart';

void main() {
  group('gradeBandForScore', () {
    test('maps percentage bands on the documented boundaries', () {
      expect(gradeBandForScore(100), GradeBand.excellent);
      expect(gradeBandForScore(90), GradeBand.excellent);
      expect(gradeBandForScore(89.9), GradeBand.good);
      expect(gradeBandForScore(80), GradeBand.good);
      expect(gradeBandForScore(79.9), GradeBand.medium);
      expect(gradeBandForScore(70), GradeBand.medium);
      expect(gradeBandForScore(69.9), GradeBand.pass);
      expect(gradeBandForScore(60), GradeBand.pass);
      expect(gradeBandForScore(59.9), GradeBand.fail);
      expect(gradeBandForScore(0), GradeBand.fail);
    });
  });

  group('gradeBandColor', () {
    final lightRed = ColorScheme.fromSeed(seedColor: const Color(0xFF8B1A2D));
    final darkRed = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8B1A2D),
      brightness: Brightness.dark,
    );
    final lightBlue = ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0));

    test('derives from the scheme primary, not hard-coded hues', () {
      final red = gradeBandColor(lightRed, GradeBand.excellent);
      final blue = gradeBandColor(lightBlue, GradeBand.excellent);

      expect(red, isNot(blue));
      // 优即 primary 本色。
      expect(red, lightRed.primary);
      expect(blue, lightBlue.primary);
    });

    test('pass tiers form a monotonic lightness ladder per brightness', () {
      double lightness(ColorScheme cs, GradeBand band) =>
          HSLColor.fromColor(gradeBandColor(cs, band)).lightness;

      for (final cs in [lightRed, darkRed]) {
        final excellent = lightness(cs, GradeBand.excellent);
        final good = lightness(cs, GradeBand.good);
        final medium = lightness(cs, GradeBand.medium);
        final pass = lightness(cs, GradeBand.pass);
        if (cs.brightness == Brightness.light) {
          expect(excellent, lessThanOrEqualTo(good));
          expect(good, lessThanOrEqualTo(medium));
          expect(medium, lessThanOrEqualTo(pass));
        } else {
          expect(excellent, greaterThanOrEqualTo(good));
          expect(good, greaterThanOrEqualTo(medium));
          expect(medium, greaterThanOrEqualTo(pass));
        }
      }
    });

    test('fail stays distinguishable from the accent in both brightness', () {
      double lightness(ColorScheme cs) =>
          HSLColor.fromColor(gradeBandColor(cs, GradeBand.fail)).lightness;

      final failLight = lightness(lightRed);
      final primaryLight = HSLColor.fromColor(lightRed.primary).lightness;
      expect(failLight, greaterThan(primaryLight));
      expect(failLight, greaterThanOrEqualTo(0.50));

      final failDark = lightness(darkRed);
      final primaryDark = HSLColor.fromColor(darkRed.primary).lightness;
      expect(failDark, lessThan(primaryDark));
    });

    test('all five bands resolve to distinct colors', () {
      for (final cs in [lightRed, darkRed, lightBlue]) {
        final colors = GradeBand.values
            .map((band) => gradeBandColor(cs, band))
            .toSet();
        expect(colors.length, GradeBand.values.length);
      }
    });
  });

  group('gradeBandColorForScore', () {
    test('resolves the band then the color', () {
      final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF8B1A2D));
      expect(
        gradeBandColorForScore(cs, 95),
        gradeBandColor(cs, GradeBand.excellent),
      );
      expect(
        gradeBandColorForScore(cs, 30),
        gradeBandColor(cs, GradeBand.fail),
      );
    });
  });
}
