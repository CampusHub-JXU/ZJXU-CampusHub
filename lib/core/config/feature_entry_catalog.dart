import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

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

class FeatureEntryConfig {
  const FeatureEntryConfig({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.iconKey,
    required this.colorKey,
    required this.routeName,
    required this.spans,
    required this.placements,
    required this.sortOrder,
  });

  final String id;
  final String title;
  final String subtitle;
  final String iconKey;
  final String colorKey;
  final String routeName;
  final FeatureEntryResponsiveSpan spans;
  final Set<FeatureEntryPlacement> placements;
  final int sortOrder;
}

class FeatureEntryDefinition {
  const FeatureEntryDefinition({
    required this.config,
    required this.icon,
    required this.accentColor,
  });

  final FeatureEntryConfig config;
  final IconData icon;
  final Color accentColor;

  String get id => config.id;
  String get title => config.title;
  String get subtitle => config.subtitle;
  String get routeName => config.routeName;
  FeatureEntryCardType get cardType =>
      FeatureEntryCatalog.cardTypeForSpan(config.spans.expanded);
  FeatureEntrySpan get span => config.spans.expanded;
  Set<FeatureEntryPlacement> get placements => config.placements;

  FeatureEntrySpan spanForGridColumns(int gridColumns) {
    return gridColumns <= 2 ? config.spans.compact : config.spans.expanded;
  }

  FeatureEntryCardType cardTypeForGridColumns(int gridColumns) {
    return FeatureEntryCatalog.cardTypeForSpan(spanForGridColumns(gridColumns));
  }
}

class FeatureEntryCatalog {
  FeatureEntryCatalog._();

  static const String _assetPath = 'assets/config/feature_entries.yaml';
  static const String _fallbackSource = '''
entries:
  - id: service-hall
    title: 服务大厅
    subtitle: 统一入口，继续保留主页快捷访问
    icon: dashboard_customize_outlined
    color: primary
    route: service-hall
    span:
      compact:
        columns: 2
        rows: 1
      expanded:
        columns: 2
        rows: 2
    placements:
      - service_hub
    sort: 10

  - id: second-classroom
    title: 第二课堂
    subtitle: 学分活动、个人中心与微信版页面
    icon: workspace_premium_outlined
    color: gold
    route: second-classroom
    span:
      compact:
        columns: 2
        rows: 1
      expanded:
        columns: 2
        rows: 1
    placements:
      - service_hub
      - home_learning
    sort: 20

  - id: library
    title: 图书馆
    subtitle: 馆藏检索、借阅与电子资源入口
    icon: local_library_outlined
    color: info
    route: library
    span:
      compact:
        columns: 2
        rows: 1
      expanded:
        columns: 2
        rows: 1
    placements:
      - service_hub
      - home_learning
    sort: 30

  - id: changxing-jiada
    title: 畅行嘉大
    subtitle: 请假、返校、离校与加班申请
    icon: north_rounded
    color: "#2EA567"
    route: changxing-jiada
    span:
      compact:
        columns: 2
        rows: 1
      expanded:
        columns: 1
        rows: 2
    placements:
      - service_hub
      - home_learning
    sort: 40

  - id: sjjx-notice-list
    title: 实践通知
    subtitle: 实践教学通知与公告聚合
    icon: science_outlined
    color: "#1976D2"
    route: sjjx-notice-list
    span:
      compact:
        columns: 1
        rows: 1
      expanded:
        columns: 1
        rows: 1
    placements:
      - service_hub
      - home_learning
    sort: 50

  - id: notice-list
    title: 校园公告
    subtitle: 校级通知与重要公告快速查看
    icon: campaign_outlined
    color: "#E7A400"
    route: notice-list
    span:
      compact:
        columns: 1
        rows: 1
      expanded:
        columns: 1
        rows: 1
    placements:
      - service_hub
    sort: 60

  - id: grades
    title: 成绩查询
    subtitle: 查看成绩、绩点和学业进展
    icon: school_outlined
    color: warning
    route: grades
    span:
      compact:
        columns: 1
        rows: 1
      expanded:
        columns: 1
        rows: 1
    placements:
      - service_hub
    sort: 70

  - id: dorm-electricity
    title: 宿舍电费
    subtitle: 查询剩余电量并管理宿舍配置
    icon: bolt_outlined
    color: "#7B61FF"
    route: dorm-electricity
    span:
      compact:
        columns: 1
        rows: 1
      expanded:
        columns: 1
        rows: 1
    placements:
      - service_hub
    sort: 80
''';

  static final FeatureEntryCatalog instance = FeatureEntryCatalog._();

  Future<List<FeatureEntryDefinition>>? _cachedEntries;

  Future<List<FeatureEntryDefinition>> loadEntries() {
    final cachedEntries = _cachedEntries;
    if (cachedEntries != null) {
      return cachedEntries;
    }
    if (kDebugMode) {
      return _loadEntries();
    }
    return _cachedEntries = _loadEntries();
  }

  Future<List<FeatureEntryDefinition>> loadByPlacement(
    FeatureEntryPlacement placement,
  ) async {
    final entries = await loadEntries();
    return entries
        .where((entry) => entry.placements.contains(placement))
        .toList(growable: false);
  }

  @visibleForTesting
  void debugSetEntries(List<FeatureEntryDefinition> entries) {
    _cachedEntries = SynchronousFuture(List.unmodifiable(entries));
  }

  @visibleForTesting
  void debugReset() {
    _cachedEntries = null;
  }

  @visibleForTesting
  List<FeatureEntryDefinition> parse(String source) {
    final root = loadYaml(source);
    if (root is! YamlMap) {
      throw const FormatException('功能入口配置格式错误');
    }

    final entriesNode = root['entries'];
    if (entriesNode is! YamlList) {
      throw const FormatException('功能入口配置缺少 entries');
    }

    final definitions = <FeatureEntryDefinition>[];
    for (var index = 0; index < entriesNode.length; index++) {
      final node = entriesNode[index];
      if (node is! YamlMap) {
        throw FormatException('功能入口第 ${index + 1} 项格式错误');
      }

      final config = FeatureEntryConfig(
        id: _requireString(node, 'id'),
        title: _requireString(node, 'title'),
        subtitle: _requireString(node, 'subtitle'),
        iconKey: _requireString(node, 'icon'),
        colorKey: _requireString(node, 'color'),
        routeName: _requireString(node, 'route'),
        spans: _parseResponsiveSpan(node['span']),
        placements: _parsePlacements(node['placements']),
        sortOrder: _parseSortOrder(node['sort'], index),
      );
      _validateCardLayout(config);

      definitions.add(
        FeatureEntryDefinition(
          config: config,
          icon: _resolveIcon(config.iconKey),
          accentColor: _resolveColor(config.colorKey),
        ),
      );
    }

    definitions.sort((left, right) {
      final compare = left.config.sortOrder.compareTo(right.config.sortOrder);
      if (compare != 0) return compare;
      return left.title.compareTo(right.title);
    });
    return List.unmodifiable(definitions);
  }

  Future<List<FeatureEntryDefinition>> _loadEntries() async {
    try {
      final source = await rootBundle.loadString(_assetPath);
      return parse(source);
    } catch (_) {
      return parse(_fallbackSource);
    }
  }

  static String _requireString(YamlMap node, String key) {
    final value = node[key];
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    throw FormatException('功能入口字段 $key 缺失');
  }

  static int _parseSortOrder(Object? value, int fallback) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static Set<FeatureEntryPlacement> _parsePlacements(Object? value) {
    if (value is! YamlList || value.isEmpty) {
      throw const FormatException('功能入口 placements 缺失');
    }

    return value.map((item) => _parsePlacement(item?.toString() ?? '')).toSet();
  }

  static FeatureEntryPlacement _parsePlacement(String value) {
    switch (value.trim()) {
      case 'service_hub':
        return FeatureEntryPlacement.serviceHub;
      case 'home_learning':
        return FeatureEntryPlacement.homeLearning;
    }
    throw FormatException('未知功能入口 placement: $value');
  }

  static FeatureEntryResponsiveSpan _parseResponsiveSpan(Object? value) {
    if (value is! YamlMap) {
      throw const FormatException('功能入口 span 缺失');
    }

    final hasResponsiveKeys =
        value['compact'] != null || value['expanded'] != null;
    if (!hasResponsiveKeys) {
      final legacy = _parseSpan(value);
      return FeatureEntryResponsiveSpan(compact: legacy, expanded: legacy);
    }

    final compact = _parseSpan(value['compact'], field: 'span.compact');
    final expanded = _parseSpan(value['expanded'], field: 'span.expanded');
    return FeatureEntryResponsiveSpan(compact: compact, expanded: expanded);
  }

  static FeatureEntrySpan _parseSpan(Object? value, {String field = 'span'}) {
    if (value is! YamlMap) {
      throw FormatException('功能入口字段 $field 缺失');
    }

    final columns = _parsePositiveInt(value['columns'], '$field.columns');
    final rows = _parsePositiveInt(value['rows'], '$field.rows');
    return FeatureEntrySpan(columns: columns, rows: rows);
  }

  static int _parsePositiveInt(Object? value, String field) {
    final number = switch (value) {
      int number => number,
      String text => int.tryParse(text.trim()),
      _ => null,
    };
    if (number != null && number > 0) {
      return number;
    }
    throw FormatException('功能入口字段 $field 非法');
  }

  static void _validateCardLayout(FeatureEntryConfig config) {
    _validateSpan(config.id, 'compact', config.spans.compact);
    _validateSpan(config.id, 'expanded', config.spans.expanded);
  }

  static void _validateSpan(String id, String scope, FeatureEntrySpan span) {
    final validSpan =
        (span.columns == 1 && span.rows == 1) ||
        (span.columns == 1 && span.rows == 2) ||
        (span.columns == 2 && span.rows == 1) ||
        (span.columns == 2 && span.rows == 2);
    if (!validSpan) {
      throw FormatException('功能入口 $id 的 $scope span 仅支持 1x1、1x2、2x1、2x2');
    }
  }

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

  static IconData _resolveIcon(String key) {
    switch (key) {
      case 'dashboard_customize_outlined':
        return Icons.dashboard_customize_outlined;
      case 'workspace_premium_outlined':
        return Icons.workspace_premium_outlined;
      case 'local_library_outlined':
        return Icons.local_library_outlined;
      case 'north_rounded':
        return Icons.north_rounded;
      case 'science_outlined':
        return Icons.science_outlined;
      case 'campaign_outlined':
        return Icons.campaign_outlined;
      case 'school_outlined':
        return Icons.school_outlined;
      case 'bolt_outlined':
        return Icons.bolt_outlined;
    }
    throw FormatException('未知功能入口图标: $key');
  }

  static Color _resolveColor(String key) {
    switch (key) {
      case 'primary':
        return AppColors.primary;
      case 'gold':
        return AppColors.gold;
      case 'info':
        return AppColors.info;
      case 'warning':
        return AppColors.warning;
    }

    final hex = key.trim();
    final normalized = hex.startsWith('#') ? hex.substring(1) : hex;
    if (normalized.length == 6) {
      final value = int.tryParse(normalized, radix: 16);
      if (value != null) {
        return Color(0xFF000000 | value);
      }
    }

    throw FormatException('未知功能入口颜色: $key');
  }
}
