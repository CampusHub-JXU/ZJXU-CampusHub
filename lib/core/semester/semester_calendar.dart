import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SemesterCalendar {
  SemesterCalendar._();

  static final SemesterCalendar instance = SemesterCalendar._();

  static const _keySemesterStartDate = 'semester_start_date_millis';
  static const _defaultStartMonth = 3;
  static const _defaultStartDay = 2;

  final ValueNotifier<DateTime> semesterStartDate = ValueNotifier<DateTime>(
    _defaultSemesterStart(DateTime.now()),
  );

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final storedMillis = prefs.getInt(_keySemesterStartDate);
    if (storedMillis == null) {
      semesterStartDate.value = _defaultSemesterStart(DateTime.now());
      return;
    }
    semesterStartDate.value = _normalize(
      DateTime.fromMillisecondsSinceEpoch(storedMillis),
    );
  }

  Future<void> setSemesterStartDate(DateTime date) async {
    final normalized = _normalize(date);
    semesterStartDate.value = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _keySemesterStartDate,
      normalized.millisecondsSinceEpoch,
    );
  }

  Future<void> resetSemesterStartDate() async {
    final defaultDate = _defaultSemesterStart(DateTime.now());
    semesterStartDate.value = defaultDate;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySemesterStartDate);
  }

  /// 第 1 教学周的周一：开学日所在周的周一。
  /// 课表网格以周一为一周起点，日期列必须与真实星期对齐
  /// （如开学日 9/1 是周二，则第 1 周从 8/31 周一起算）。
  DateTime get weekOneStartDate {
    final day = _normalize(semesterStartDate.value);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// 第 [week] 教学周的周一日期。
  DateTime weekStartFor(int week) =>
      weekOneStartDate.add(Duration(days: (week - 1) * 7));

  int weekForDate(DateTime date) {
    final day = _normalize(date);
    final diff = day.difference(_normalize(weekOneStartDate)).inDays;
    return ((diff ~/ 7) + 1).clamp(1, 20);
  }

  /// 指定日期（默认今天）是否还未进入教学周（第 1 周周一日之前）。
  /// 此时 [weekForDate] 被钳制到第 1 周，但不应视作"本周"。
  bool isBeforeSemesterStart([DateTime? date]) {
    final day = _normalize(date ?? DateTime.now());
    return day.isBefore(_normalize(weekOneStartDate));
  }

  /// 指定日期（默认今天）是否已超出本学期教学周范围（20 周之后）。
  bool isAfterSemesterEnd([DateTime? date]) {
    final day = _normalize(date ?? DateTime.now());
    return day.difference(_normalize(semesterStartDate.value)).inDays >= 20 * 7;
  }

  /// 默认开学日期：秋季学期按 9 月 1 日，春季学期按 3 月 2 日推算。
  /// 仅在用户未手动设置开学日期时使用，可在设置中覆盖。
  static DateTime defaultSemesterStartFor(DateTime now) {
    if (now.month >= 8) return DateTime(now.year, 9, 1);
    if (now.month <= 2) return DateTime(now.year - 1, 9, 1);
    return DateTime(now.year, _defaultStartMonth, _defaultStartDay);
  }

  static DateTime _defaultSemesterStart(DateTime now) {
    return defaultSemesterStartFor(now);
  }

  static DateTime _normalize(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }
}
