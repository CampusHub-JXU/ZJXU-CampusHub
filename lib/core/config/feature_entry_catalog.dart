import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';

enum FeatureEntryPlacement { serviceHub, homeLearning }

enum FeatureEntryCardType { smallSquare, tallRect, wideRect, largeSquare }

class FeatureEntrySpan {
  const FeatureEntrySpan({required this.columns, required this.rows});

  final int columns;
  final int rows;
}

class FeatureEntryResponsiveSpan {
  const FeatureEntryResponsiveSpan({
    required this.compact,
    required this.expanded,
  });

  final FeatureEntrySpan compact;
  final FeatureEntrySpan expanded;
}

class FeatureEntryDefinition {
  const FeatureEntryDefinition({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.routeName,
    required this.spans,
    required this.placements,
    required this.sortOrder,
    this.isVisible = true,
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final String routeName;
  final FeatureEntryResponsiveSpan spans;
  final Set<FeatureEntryPlacement> placements;
  final int sortOrder;
  final bool isVisible;

  FeatureEntryCardType get cardType =>
      FeatureEntryCatalog.cardTypeForSpan(spans.expanded);

  FeatureEntrySpan get span => spans.expanded;

  FeatureEntrySpan spanForGridColumns(int gridColumns) {
    return gridColumns <= 2 ? spans.compact : spans.expanded;
  }

  FeatureEntryCardType cardTypeForGridColumns(int gridColumns) {
    return FeatureEntryCatalog.cardTypeForSpan(spanForGridColumns(gridColumns));
  }
}

class AppFeaturesConfig {
  AppFeaturesConfig._();

  static const List<FeatureEntryDefinition> entries = [
    FeatureEntryDefinition(
      id: 'service-hall',
      title: '服务大厅',
      subtitle: '统一入口，继续保留主页快捷访问',
      icon: Icons.dashboard_customize_outlined,
      accentColor: AppColors.primary,
      routeName: 'service-hall',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 2, rows: 1),
        expanded: FeatureEntrySpan(columns: 2, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 10,
    ),
    FeatureEntryDefinition(
      id: 'second-classroom',
      title: '第二课堂',
      subtitle: '学分活动、个人中心与微信版页面',
      icon: Icons.workspace_premium_outlined,
      accentColor: AppColors.gold,
      routeName: 'second-classroom',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {
        FeatureEntryPlacement.serviceHub,
        FeatureEntryPlacement.homeLearning,
      },
      sortOrder: 20,
    ),
    FeatureEntryDefinition(
      id: 'library',
      title: '图书馆',
      subtitle: '馆藏检索、借阅与电子资源入口',
      icon: Icons.local_library_outlined,
      accentColor: AppColors.info,
      routeName: 'library',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {
        FeatureEntryPlacement.serviceHub,
        FeatureEntryPlacement.homeLearning,
      },
      sortOrder: 30,
    ),
    FeatureEntryDefinition(
      id: 'changxing-jiada',
      title: '畅行嘉大',
      subtitle: '请假、返校、离校与加班申请',
      icon: Icons.north_rounded,
      accentColor: Color(0xFF2EA567),
      routeName: 'changxing-jiada',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 40,
    ),
    FeatureEntryDefinition(
      id: 'sjjx-notice-list',
      title: '实践通知',
      subtitle: '实践教学通知与公告聚合',
      icon: Icons.science_outlined,
      accentColor: Color(0xFF1976D2),
      routeName: 'sjjx-notice-list',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 50,
    ),
    FeatureEntryDefinition(
      id: 'notice-list',
      title: '校园公告',
      subtitle: '校级通知与重要公告快速查看',
      icon: Icons.campaign_outlined,
      accentColor: Color(0xFFE7A400),
      routeName: 'notice-list',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 60,
    ),
    FeatureEntryDefinition(
      id: 'grades',
      title: '成绩查询',
      subtitle: '查看成绩、绩点和学业进展',
      icon: Icons.school_outlined,
      accentColor: AppColors.warning,
      routeName: 'grades',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 70,
    ),
    FeatureEntryDefinition(
      id: 'dorm-electricity',
      title: '宿舍电费',
      subtitle: '查询剩余电量并管理宿舍配置',
      icon: Icons.bolt_outlined,
      accentColor: Color(0xFF7B61FF),
      routeName: 'dorm-electricity',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 80,
    ),
  ];

  static final List<FeatureEntryDefinition> _activeEntries =
      _normalizeFeatureEntries(entries);

  static List<FeatureEntryDefinition> get activeEntries => _activeEntries;

  static List<FeatureEntryDefinition> activeEntriesForPlacement(
    FeatureEntryPlacement placement,
  ) {
    return List.unmodifiable(
      _activeEntries.where((entry) => entry.placements.contains(placement)),
    );
  }
}

class FeatureEntryCatalog {
  FeatureEntryCatalog._();

  static final FeatureEntryCatalog instance = FeatureEntryCatalog._();

  List<FeatureEntryDefinition>? _debugEntries;

  Future<List<FeatureEntryDefinition>> loadEntries() {
    return SynchronousFuture(_entries);
  }

  Future<List<FeatureEntryDefinition>> loadByPlacement(
    FeatureEntryPlacement placement,
  ) {
    return SynchronousFuture(entriesByPlacement(placement));
  }

  List<FeatureEntryDefinition> entriesByPlacement(
    FeatureEntryPlacement placement,
  ) {
    return List.unmodifiable(
      _entries.where((entry) => entry.placements.contains(placement)),
    );
  }

  @visibleForTesting
  void debugSetEntries(List<FeatureEntryDefinition> entries) {
    _debugEntries = _normalizeFeatureEntries(entries);
  }

  @visibleForTesting
  void debugReset() {
    _debugEntries = null;
  }

  List<FeatureEntryDefinition> get _entries =>
      _debugEntries ?? AppFeaturesConfig.activeEntries;

  static FeatureEntryCardType cardTypeForSpan(FeatureEntrySpan span) {
    if (span.columns == 1 && span.rows == 1) {
      return FeatureEntryCardType.smallSquare;
    }
    if (span.columns == 1 && span.rows == 2) {
      return FeatureEntryCardType.tallRect;
    }
    if (span.columns == 2 && span.rows == 1) {
      return FeatureEntryCardType.wideRect;
    }
    if (span.columns == 2 && span.rows == 2) {
      return FeatureEntryCardType.largeSquare;
    }
    throw FormatException('未知功能入口 span: ${span.columns}x${span.rows}');
  }
}

List<FeatureEntryDefinition> _normalizeFeatureEntries(
  Iterable<FeatureEntryDefinition> entries,
) {
  final normalized = entries.where((entry) => entry.isVisible).toList();
  normalized.sort(_compareFeatureEntries);
  for (final entry in normalized) {
    _validateFeatureEntry(entry);
  }
  return List.unmodifiable(normalized);
}

int _compareFeatureEntries(
  FeatureEntryDefinition left,
  FeatureEntryDefinition right,
) {
  final sortCompare = left.sortOrder.compareTo(right.sortOrder);
  if (sortCompare != 0) {
    return sortCompare;
  }
  return left.title.compareTo(right.title);
}

void _validateFeatureEntry(FeatureEntryDefinition entry) {
  if (entry.id.trim().isEmpty) {
    throw const FormatException('功能入口 id 缺失');
  }
  if (entry.title.trim().isEmpty) {
    throw FormatException('功能入口 ${entry.id} 的标题缺失');
  }
  if (entry.routeName.trim().isEmpty) {
    throw FormatException('功能入口 ${entry.id} 的 routeName 缺失');
  }
  if (entry.placements.isEmpty) {
    throw FormatException('功能入口 ${entry.id} 的 placements 缺失');
  }
  _validateFeatureSpan(entry.id, 'compact', entry.spans.compact);
  _validateFeatureSpan(entry.id, 'expanded', entry.spans.expanded);
}

void _validateFeatureSpan(String id, String scope, FeatureEntrySpan span) {
  final validSpan =
      (span.columns == 1 && span.rows == 1) ||
      (span.columns == 1 && span.rows == 2) ||
      (span.columns == 2 && span.rows == 1) ||
      (span.columns == 2 && span.rows == 2);
  if (!validSpan) {
    throw FormatException('功能入口 $id 的 $scope span 仅支持 1x1、1x2、2x1、2x2');
  }
}
