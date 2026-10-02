/// 中国法定节假日（国务院办公厅年度放假安排）静态表，纯数据 + 纯函数。
///
/// 只收录「放假日」；调休上班日（如 2026-09-20 周日）不在表内——那一天
/// 实际上什么课由学校调课通知决定，交给课表的调课规则处理。
///
/// 维护：国务院一般在每年 11 月发布次年安排，发布后在 [_holidayRanges]
/// 追加一年并补测试。表外年份查询一律返回 null（不猜测），首页只依赖
/// 课表本身判断停课日。
library;

import 'package:flutter/foundation.dart';

/// 一段法定假期（闭区间，按本地日期）。
class ChinaPublicHoliday {
  const ChinaPublicHoliday(this.name, this.start, this.end);

  /// 节日名，如「国庆节」。
  final String name;
  final DateTime start;
  final DateTime end;

  bool contains(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return !day.isBefore(start) && !day.isAfter(end);
  }
}

/// 2026 年：国务院办公厅《关于 2026 年部分节假日安排的通知》
/// （2025-11-04 发布）。
final List<ChinaPublicHoliday> _holidayRanges = [
  ChinaPublicHoliday('元旦', DateTime(2026, 1, 1), DateTime(2026, 1, 3)),
  ChinaPublicHoliday('春节', DateTime(2026, 2, 15), DateTime(2026, 2, 23)),
  ChinaPublicHoliday('清明节', DateTime(2026, 4, 4), DateTime(2026, 4, 6)),
  ChinaPublicHoliday('劳动节', DateTime(2026, 5, 1), DateTime(2026, 5, 5)),
  ChinaPublicHoliday('端午节', DateTime(2026, 6, 19), DateTime(2026, 6, 21)),
  ChinaPublicHoliday('中秋节', DateTime(2026, 9, 25), DateTime(2026, 9, 27)),
  ChinaPublicHoliday('国庆节', DateTime(2026, 10, 1), DateTime(2026, 10, 7)),
];

/// 测试替换节假日表：依赖真实时钟（[DateTime.now]）的 widget 测试置为
/// `const []`，避免恰好在法定假期运行时课程被当作放假；用完置回 null。
@visibleForTesting
List<ChinaPublicHoliday>? debugChinaPublicHolidaysOverride;

/// [date] 所在的法定假期；不在任何假期内（或年份未收录）时返回 null。
ChinaPublicHoliday? chinaPublicHolidayOn(DateTime date) {
  for (final holiday in debugChinaPublicHolidaysOverride ?? _holidayRanges) {
    if (holiday.contains(date)) return holiday;
  }
  return null;
}
