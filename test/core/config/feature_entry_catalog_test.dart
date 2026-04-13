import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';

void main() {
  tearDown(() {
    FeatureEntryCatalog.instance.debugReset();
  });

  group('FeatureEntryCatalog', () {
    test('exposes resolved feature definitions from pure dart config', () {
      final entries = AppFeaturesConfig.activeEntries;
      final library = entries.firstWhere((entry) => entry.id == 'library');
      final changxing = entries.firstWhere(
        (entry) => entry.id == 'changxing-jiada',
      );

      expect(entries, isNotEmpty);
      expect(library.title, '图书馆');
      expect(library.routeName, 'library');
      expect(library.icon, Icons.local_library_outlined);
      expect(library.accentColor, AppColors.info);
      expect(library.cardType, FeatureEntryCardType.smallSquare);
      expect(library.span.columns, 1);
      expect(library.span.rows, 1);
      expect(library.spanForGridColumns(2).columns, 1);
      expect(library.spanForGridColumns(2).rows, 1);
      expect(
        library.placements,
        containsAll(<FeatureEntryPlacement>[
          FeatureEntryPlacement.serviceHub,
          FeatureEntryPlacement.homeLearning,
        ]),
      );
      expect(changxing.accentColor, const Color(0xFF2EA567));
    });

    test('filters hidden entries and placement specific entries', () {
      FeatureEntryCatalog.instance.debugSetEntries([
        _entry(
          id: 'visible',
          title: '可见功能',
          placements: const {FeatureEntryPlacement.serviceHub},
          sortOrder: 20,
        ),
        _entry(
          id: 'hidden',
          title: '隐藏功能',
          placements: const {FeatureEntryPlacement.serviceHub},
          sortOrder: 10,
          isVisible: false,
        ),
        _entry(
          id: 'home-only',
          title: '首页功能',
          placements: const {FeatureEntryPlacement.homeLearning},
          sortOrder: 30,
        ),
      ]);

      final serviceHubEntries = FeatureEntryCatalog.instance.entriesByPlacement(
        FeatureEntryPlacement.serviceHub,
      );
      final homeEntries = FeatureEntryCatalog.instance.entriesByPlacement(
        FeatureEntryPlacement.homeLearning,
      );

      expect(serviceHubEntries.map((entry) => entry.id), ['visible']);
      expect(homeEntries.map((entry) => entry.id), ['home-only']);
    });

    test('rejects unsupported span sizes', () {
      expect(
        () => FeatureEntryCatalog.instance.debugSetEntries([
          _entry(
            id: 'invalid-span',
            spans: const FeatureEntryResponsiveSpan(
              compact: FeatureEntrySpan(columns: 3, rows: 1),
              expanded: FeatureEntrySpan(columns: 1, rows: 1),
            ),
          ),
        ]),
        throwsFormatException,
      );
    });

    test('uses compact and expanded spans for different grid widths', () {
      final entry = _entry(
        id: 'responsive',
        spans: const FeatureEntryResponsiveSpan(
          compact: FeatureEntrySpan(columns: 2, rows: 1),
          expanded: FeatureEntrySpan(columns: 2, rows: 2),
        ),
      );

      expect(entry.cardTypeForGridColumns(2), FeatureEntryCardType.wideRect);
      expect(entry.cardTypeForGridColumns(4), FeatureEntryCardType.largeSquare);
    });
  });
}

FeatureEntryDefinition _entry({
  required String id,
  String? title,
  String subtitle = '测试副标题',
  IconData icon = Icons.extension_outlined,
  Color accentColor = AppColors.primary,
  String? routeName,
  FeatureEntryResponsiveSpan spans = const FeatureEntryResponsiveSpan(
    compact: FeatureEntrySpan(columns: 1, rows: 1),
    expanded: FeatureEntrySpan(columns: 1, rows: 1),
  ),
  Set<FeatureEntryPlacement> placements = const {
    FeatureEntryPlacement.serviceHub,
  },
  int sortOrder = 10,
  bool isVisible = true,
}) {
  return FeatureEntryDefinition(
    id: id,
    title: title ?? id,
    subtitle: subtitle,
    icon: icon,
    accentColor: accentColor,
    routeName: routeName ?? id,
    spans: spans,
    placements: placements,
    sortOrder: sortOrder,
    isVisible: isVisible,
  );
}
