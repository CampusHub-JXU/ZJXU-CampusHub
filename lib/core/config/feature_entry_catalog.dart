import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';

enum FeatureEntryPlacement { serviceHub, homeLearning }

enum FeatureEntryCardType { smallSquare, tallRect, wideRect, largeSquare }

enum FeatureEntryCategory {
  academic('学业'),
  campusLife('校园生活'),
  notices('通知公告'),
  servicesAccounts('办事与账号');

  const FeatureEntryCategory(this.label);

  final String label;
}

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
    this.category = FeatureEntryCategory.servicesAccounts,
    this.keywords = const [],
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
  final FeatureEntryCategory category;
  final List<String> keywords;
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
      id: 'schedule',
      title: '课表',
      subtitle: '查看本学期课程、周次与调课提醒',
      icon: Icons.calendar_month_outlined,
      accentColor: AppColors.primary,
      routeName: 'schedule',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 5,
      category: FeatureEntryCategory.academic,
      keywords: ['课程', '教务', '上课', '调课'],
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
      sortOrder: 10,
      category: FeatureEntryCategory.academic,
      keywords: ['绩点', '分数', '教务'],
    ),
    FeatureEntryDefinition(
      id: 'exam',
      title: '考试安排',
      subtitle: '查看考试时间、地点与倒计时',
      icon: Icons.event_available_outlined,
      accentColor: Color(0xFF7B61FF),
      routeName: 'exam',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 15,
      category: FeatureEntryCategory.academic,
      keywords: ['期末', '考场', '教务'],
    ),
    FeatureEntryDefinition(
      id: 'shuati-practice',
      title: '刷题助手',
      subtitle: '题库导入、错题重练、离线练习',
      icon: Icons.quiz_outlined,
      accentColor: Color(0xFF00897B),
      routeName: 'shuati-practice',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 20,
      category: FeatureEntryCategory.academic,
      keywords: ['题库', '练习', '错题', '考试', '复习'],
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
      sortOrder: 25,
      category: FeatureEntryCategory.academic,
      keywords: ['活动', '学分', '德育'],
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
      category: FeatureEntryCategory.academic,
      keywords: ['借书', '馆藏', '座位', '电子资源'],
    ),
    FeatureEntryDefinition(
      id: 'campus-card',
      title: '一卡通',
      subtitle: '余额查询、校园卡服务与充值入口',
      icon: Icons.credit_card_outlined,
      accentColor: Color(0xFF1E88E5),
      routeName: 'campus-card',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 40,
      category: FeatureEntryCategory.campusLife,
      keywords: ['余额', '充值', '校园卡', '小付宝'],
    ),
    FeatureEntryDefinition(
      id: 'dorm-electricity',
      title: '宿舍电费',
      subtitle: '查询寝室剩余电量与低电量提醒',
      icon: Icons.bolt_outlined,
      accentColor: Color(0xFFFFB300),
      routeName: 'dorm-electricity',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 45,
      category: FeatureEntryCategory.campusLife,
      keywords: ['寝室', '电量', '宿舍', '低电量'],
    ),
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
      sortOrder: 50,
      category: FeatureEntryCategory.servicesAccounts,
      keywords: ['办事', '移动大厅', '流程'],
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
      sortOrder: 55,
      category: FeatureEntryCategory.servicesAccounts,
      keywords: ['请假', '返校', '离校', '加班'],
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
      sortOrder: 60,
      category: FeatureEntryCategory.notices,
      keywords: ['实践', '教学', '通知', '公告'],
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
      sortOrder: 65,
      category: FeatureEntryCategory.notices,
      keywords: ['通知', '公告', '新闻', '教务'],
    ),
    FeatureEntryDefinition(
      id: 'notification-center',
      title: '通知中心',
      subtitle: '集中查看课程、考试与系统提醒',
      icon: Icons.notifications_outlined,
      accentColor: Color(0xFF546E7A),
      routeName: 'notification-center',
      spans: FeatureEntryResponsiveSpan(
        compact: FeatureEntrySpan(columns: 1, rows: 1),
        expanded: FeatureEntrySpan(columns: 1, rows: 1),
      ),
      placements: {FeatureEntryPlacement.serviceHub},
      sortOrder: 70,
      category: FeatureEntryCategory.notices,
      keywords: ['提醒', '消息', '通知'],
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
