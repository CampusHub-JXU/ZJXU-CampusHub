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

class FeatureEntryConfig {
  const FeatureEntryConfig({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.iconKey,
    required this.colorKey,
    required this.routeName,
    required this.cardType,
    required this.span,
    required this.placements,
    required this.sortOrder,
  });

  final String id;
  final String title;
  final String subtitle;
  final String iconKey;
  final String colorKey;
  final String routeName;
  final FeatureEntryCardType cardType;
  final FeatureEntrySpan span;
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
  FeatureEntryCardType get cardType => config.cardType;
  FeatureEntrySpan get span => config.span;
  Set<FeatureEntryPlacement> get placements => config.placements;
}

class FeatureEntryCatalog {
  FeatureEntryCatalog._();

  static const String _assetPath = 'assets/config/feature_entries.yaml';

  static final FeatureEntryCatalog instance = FeatureEntryCatalog._();

  Future<List<FeatureEntryDefinition>>? _cachedEntries;

  Future<List<FeatureEntryDefinition>> loadEntries() {
    return _cachedEntries ??= _loadEntries();
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
        cardType: _parseCardType(node['cardType']),
        span: _parseSpan(node['span']),
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
    final source = await rootBundle.loadString(_assetPath);
    return parse(source);
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

  static FeatureEntryCardType _parseCardType(Object? value) {
    final text = value?.toString().trim() ?? '';
    switch (text) {
      case 'small_square':
        return FeatureEntryCardType.smallSquare;
      case 'tall_rect':
        return FeatureEntryCardType.tallRect;
      case 'wide_rect':
        return FeatureEntryCardType.wideRect;
      case 'large_square':
        return FeatureEntryCardType.largeSquare;
    }
    throw FormatException('未知功能入口 cardType: $text');
  }

  static FeatureEntrySpan _parseSpan(Object? value) {
    if (value is! YamlMap) {
      throw const FormatException('功能入口 span 缺失');
    }

    final columns = _parsePositiveInt(value['columns'], 'span.columns');
    final rows = _parsePositiveInt(value['rows'], 'span.rows');
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
    final span = config.span;
    final validSpan =
        (span.columns == 1 && span.rows == 1) ||
        (span.columns == 1 && span.rows == 2) ||
        (span.columns == 2 && span.rows == 1) ||
        (span.columns == 2 && span.rows == 2);
    if (!validSpan) {
      throw FormatException('功能入口 ${config.id} 的 span 仅支持 1x1、1x2、2x1、2x2');
    }

    final matchesType = switch (config.cardType) {
      FeatureEntryCardType.smallSquare => span.columns == 1 && span.rows == 1,
      FeatureEntryCardType.tallRect => span.columns == 1 && span.rows == 2,
      FeatureEntryCardType.wideRect => span.columns == 2 && span.rows == 1,
      FeatureEntryCardType.largeSquare => span.columns == 2 && span.rows == 2,
    };
    if (!matchesType) {
      throw FormatException('功能入口 ${config.id} 的 cardType 与 span 不匹配');
    }
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
