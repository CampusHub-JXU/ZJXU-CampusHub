import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'campus_card_bill_gateway.dart';

/// 一条真实消费记录（移动大厅「校园卡账单」的「近期消费(近五次)」表）。
///
/// 与「充值流水」(epay100 `app.portal.getBillList`) 是两套数据：后者记录的是
/// 银行卡 → 校园卡的渠道扣款，本类记录的是**卡内实际消费**（食堂/超市刷卡）。
/// 服务端只给消费日期（不含时刻）、地点与金额，金额为正数支出（元）。
@immutable
class CampusCardConsumptionEntry {
  const CampusCardConsumptionEntry({
    required this.date,
    required this.location,
    required this.amount,
  });

  /// 消费日期；解析失败时为 null（展示层隐藏日期，不伪造）。
  final DateTime? date;

  /// 消费地点（如「梅园餐厅二楼」）。
  final String location;

  /// 支出金额（正数，元）。
  final double amount;
}

/// 单个餐次的累计消费（「三餐消费(近消费七日)」饼图）。
@immutable
class CampusCardMealSpend {
  const CampusCardMealSpend({required this.label, required this.amount});

  /// 餐次名：早餐 / 午餐 / 晚餐（服务端 `中餐` 归一为 `午餐`）。
  final String label;

  /// 该餐次近七日累计支出（正数，元）。
  final double amount;
}

/// 单日消费合计（「消费统计(近七日)」柱状图的「消费金额」系列）。
@immutable
class CampusCardDaySpend {
  const CampusCardDaySpend({
    required this.label,
    required this.amount,
    required this.count,
  });

  /// 日期标签，服务端给 `MM-dd`。
  final String label;

  /// 当日消费金额（正数，元）。
  final double amount;

  /// 当日消费笔数（同一图表的「次数」系列）。
  final int count;
}

/// 校园卡账单快照：四个统计格 + 近期消费 + 三餐 / 单日统计。
@immutable
class CampusCardConsumptionSummary {
  const CampusCardConsumptionSummary({
    required this.todaySpend,
    required this.cardBalance,
    required this.weekSpend,
    required this.monthSpend,
    required this.recent,
    required this.meals,
    required this.dailyTrend,
    required this.fetchedAt,
  });

  /// 今日消费（元）。
  final double todaySpend;

  /// 卡内余额（官方账单页口径，元）。
  final double cardBalance;

  /// 本周消费（元）。
  final double weekSpend;

  /// 本月消费（元）。
  final double monthSpend;

  /// 近期消费（服务端按时间倒序给最近五条）。
  final List<CampusCardConsumptionEntry> recent;

  /// 三餐消费（近消费七日），按早餐 / 午餐 / 晚餐排序。
  final List<CampusCardMealSpend> meals;

  /// 单日消费统计（近消费七日）。
  final List<CampusCardDaySpend> dailyTrend;

  final DateTime fetchedAt;

  /// 所有区块都为空：账单页据此显示空态。
  bool get isEmpty =>
      recent.isEmpty &&
      meals.isEmpty &&
      dailyTrend.isEmpty &&
      todaySpend == 0 &&
      weekSpend == 0 &&
      monthSpend == 0;

  /// 近七日三餐最大值，用于条形图归一（全为 0 时返回 0，由展示层兜底）。
  double get mealPeak => meals.fold<double>(
    0,
    (max, meal) => meal.amount > max ? meal.amount : max,
  );

  /// 今日最大单日消费，用于条形图归一。
  double get dayPeak => dailyTrend.fold<double>(
    0,
    (max, day) => day.amount > max ? day.amount : max,
  );

  static const _statWidgets = <String, String>{
    'ZTXF1': 'today',
    'ZTXF2': 'balance',
    'ZTXF3': 'week',
    'ZTXF4': 'month',
  };

  /// 解析网关抓回的原始 widget / 图表响应。
  ///
  /// 任一区块解析失败只让该区块为空，不影响其余区块；只有当**全部**区块都
  /// 拿不到数据时抛 [CampusCardBillException]（多半是会话过期 / 服务端异常）。
  factory CampusCardConsumptionSummary.parse(
    CampusCardBillRawPayload raw, {
    DateTime? now,
  }) {
    final stats = <String, double>{};
    var parsedAny = false;
    for (final entry in _statWidgets.entries) {
      final value = _parseStatValue(raw.widgets[entry.key]);
      if (value == null) continue;
      stats[entry.value] = value;
      parsedAny = true;
    }

    final recent = _parseRecent(
      raw.widgets[CampusCardBillGateway.recentWidget],
    );
    final meals = _parseMeals(
      raw.charts[CampusCardBillGateway.chartWidgets[0]],
    );
    final trend = _parseDaily(
      raw.charts[CampusCardBillGateway.chartWidgets[1]],
    );

    if (!parsedAny && recent.isEmpty && meals.isEmpty && trend.isEmpty) {
      final looksLikeHtml = raw.widgets.values.any(
        (body) => body.trimLeft().startsWith('<'),
      );
      throw CampusCardBillException(
        looksLikeHtml ? '账单服务返回异常页面，请稍后重试' : '账单数据为空，请稍后重试',
      );
    }

    return CampusCardConsumptionSummary(
      todaySpend: stats['today'] ?? 0,
      cardBalance: stats['balance'] ?? 0,
      weekSpend: stats['week'] ?? 0,
      monthSpend: stats['month'] ?? 0,
      recent: recent,
      meals: meals,
      dailyTrend: trend,
      fetchedAt: now ?? DateTime.now(),
    );
  }

  // ── 解析实现 ────────────────────────────────────────────────────────────

  /// 统计格：`rows[1]` 里第一个可解析为数字的单元格（列 0 是数值，列 1 是
  /// 带颜色的 HTML 版本，两者同值）。
  static double? _parseStatValue(String? body) {
    final rows = _rowsOf(body);
    if (rows == null) return null;
    for (final row in rows) {
      for (final cell in _cellsOf(row)) {
        final value = _toDouble(cell['text']);
        if (value != null) return value;
      }
    }
    return null;
  }

  static List<CampusCardConsumptionEntry> _parseRecent(String? body) {
    final rows = _rowsOf(body);
    if (rows == null) return const [];
    var dateColumn = -1;
    var locationColumn = -1;
    var amountColumn = -1;
    var headerIndex = -1;
    for (var i = 0; i < rows.length; i++) {
      final cells = _cellMap(rows[i]);
      for (final entry in cells.entries) {
        final text = entry.value.trim();
        if (text == '消费日期') {
          dateColumn = entry.key;
          headerIndex = i;
        } else if (text == '消费地点') {
          locationColumn = entry.key;
        } else if (text == '消费金额') {
          amountColumn = entry.key;
        }
      }
      if (headerIndex >= 0) break;
    }
    if (headerIndex < 0 || dateColumn < 0 || amountColumn < 0) return const [];

    final entries = <CampusCardConsumptionEntry>[];
    for (var i = headerIndex + 1; i < rows.length; i++) {
      final cells = _cellMap(rows[i]);
      final dateText = cells[dateColumn]?.trim() ?? '';
      final amount = _toDouble(cells[amountColumn]);
      if (dateText.isEmpty && amount == null) continue;
      final location = locationColumn < 0
          ? ''
          : (cells[locationColumn]?.trim() ?? '');
      entries.add(
        CampusCardConsumptionEntry(
          date: _parseDate(dateText),
          location: location.isEmpty ? '未知地点' : location,
          amount: amount ?? 0,
        ),
      );
    }
    return List.unmodifiable(entries);
  }

  static List<CampusCardMealSpend> _parseMeals(dynamic chart) {
    final series = _chartSeries(chart);
    if (series == null || series.isEmpty) return const [];
    final data = _seriesData(series.first);
    if (data.isEmpty) return const [];
    final meals = <String, double>{};
    for (final item in data) {
      final label = _normalizeMealLabel(
        (item['x'] ?? item['originalCategory'] ?? '').toString(),
      );
      final value = _toDouble(item['y']);
      if (label.isEmpty || value == null) continue;
      meals[label] = (meals[label] ?? 0) + value;
    }
    final ordered = <CampusCardMealSpend>[];
    for (final label in const ['早餐', '午餐', '晚餐']) {
      final value = meals.remove(label);
      if (value != null) {
        ordered.add(CampusCardMealSpend(label: label, amount: value));
      }
    }
    for (final entry in meals.entries) {
      ordered.add(CampusCardMealSpend(label: entry.key, amount: entry.value));
    }
    return List.unmodifiable(ordered);
  }

  static List<CampusCardDaySpend> _parseDaily(dynamic chart) {
    final series = _chartSeries(chart);
    if (series == null || series.isEmpty) return const [];
    final amounts = <String, double>{};
    final counts = <String, int>{};
    for (final item in series) {
      final name = (item['name'] ?? '').toString();
      final type = (item['type'] ?? '').toString();
      final data = _seriesData(item);
      final isCount = name.contains('次数') || type == 'line';
      for (final point in data) {
        final label = (point['x'] ?? point['originalCategory'] ?? '')
            .toString();
        if (label.isEmpty) continue;
        final value = _toDouble(point['y']);
        if (value == null) continue;
        if (isCount) {
          counts[label] = value.round();
        } else {
          amounts[label] = (amounts[label] ?? 0) + value;
        }
      }
    }
    if (amounts.isEmpty) return const [];
    final days = <CampusCardDaySpend>[
      for (final entry in amounts.entries)
        CampusCardDaySpend(
          label: entry.key,
          amount: entry.value,
          count: counts[entry.key] ?? 0,
        ),
    ];
    days.sort((a, b) => a.label.compareTo(b.label));
    return List.unmodifiable(days);
  }

  static String _normalizeMealLabel(String raw) {
    final text = raw.trim();
    switch (text) {
      case '中餐':
        return '午餐';
      case '':
        return '';
      default:
        return text;
    }
  }

  static List<dynamic>? _chartSeries(dynamic chart) {
    final map = _asMap(chart);
    final data = map?['data'];
    final payload = data is String ? _decode(data) : _asMap(data);
    final attr = _asMap(payload?['chartAttr']);
    final series = attr?['series'];
    return series is List ? series : null;
  }

  static List<Map<String, dynamic>> _seriesData(dynamic series) {
    final map = _asMap(series);
    final data = map?['data'];
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (_asMap(item) != null) _asMap(item)!,
    ];
  }

  static List<dynamic>? _rowsOf(String? body) {
    final payload = _decode(body);
    final pageContent = _asMap(payload?['pageContent']);
    final detail = pageContent?['detail'];
    if (detail is! List || detail.isEmpty) return null;
    final first = _asMap(detail.first);
    final cellData = _asMap(first?['cellData']);
    final rows = cellData?['rows'];
    return rows is List ? rows : null;
  }

  static List<Map<String, dynamic>> _cellsOf(dynamic row) {
    final map = _asMap(row);
    final cells = map?['cells'];
    if (cells is! List) return const [];
    return [
      for (final cell in cells)
        if (_asMap(cell) != null) _asMap(cell)!,
    ];
  }

  static Map<int, String> _cellMap(dynamic row) {
    final result = <int, String>{};
    for (final cell in _cellsOf(row)) {
      final column = cell['col'];
      final index = column is num ? column.toInt() : int.tryParse('$column');
      if (index == null) continue;
      result[index] = (cell['text'] ?? '').toString();
    }
    return result;
  }

  static Map<String, dynamic>? _decode(String? body) {
    if (body == null) return null;
    final text = body.trim();
    if (text.isEmpty || text.startsWith('<')) return null;
    try {
      final decoded = jsonDecode(text);
      return _asMap(decoded);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    final text = (value ?? '').toString().trim().replaceAll(',', '');
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    if (parsed != null) return parsed;
    // 部分格子把数值包在 HTML 里（如 `<span>16.3</span><span>元</span>`）。
    final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(text);
    return match == null ? null : double.tryParse(match.group(0)!);
  }

  static DateTime? _parseDate(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text.replaceAll('/', '-'));
  }
}
