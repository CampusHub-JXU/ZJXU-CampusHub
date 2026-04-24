import 'package:flutter/material.dart';

import '../../core/config/feature_entry_catalog.dart';

int serviceHubGridColumnCount(double maxWidth) => maxWidth >= 600 ? 4 : 2;

Alignment serviceHubChevronAlignment(int rowSpan) {
  return Alignment.bottomRight;
}

double serviceHubCardMinHeight(
  FeatureEntryCardType cardType,
  double cardWidth,
) {
  final preferred = switch (cardType) {
    FeatureEntryCardType.smallSquare => cardWidth * 0.68,
    FeatureEntryCardType.tallRect => cardWidth * 1.02,
    FeatureEntryCardType.wideRect => cardWidth * 0.42,
    FeatureEntryCardType.largeSquare => cardWidth * 0.56,
  };
  final min = switch (cardType) {
    FeatureEntryCardType.smallSquare => 120.0,
    FeatureEntryCardType.tallRect => 176.0,
    FeatureEntryCardType.wideRect => 132.0,
    FeatureEntryCardType.largeSquare => 168.0,
  };
  final max = switch (cardType) {
    FeatureEntryCardType.smallSquare => 160.0,
    FeatureEntryCardType.tallRect => 220.0,
    FeatureEntryCardType.wideRect => 172.0,
    FeatureEntryCardType.largeSquare => 220.0,
  };
  return preferred.clamp(min, max);
}

FeatureEntrySpan serviceHubActiveSpan(
  FeatureEntryDefinition entry,
  int gridColumns,
) {
  return entry.spanForGridColumns(gridColumns);
}

FeatureEntryCardType serviceHubActiveCardType(
  FeatureEntryDefinition entry,
  int gridColumns,
) {
  return entry.cardTypeForGridColumns(gridColumns);
}
