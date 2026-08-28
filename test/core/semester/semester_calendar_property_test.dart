import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';

import '../../helpers/property.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const semesterWeeks = 20;
  const semesterTotalDays = semesterWeeks * 7;

  final startGen = dateTimesNear(
    DateTime(2026, 3, 2),
    minOffsetDays: -400,
    maxOffsetDays: 400,
    withTime: true,
  );

  Gen<(DateTime, int)> startWithOffset() {
    return pair(startGen, intsInRange(-90, 220));
  }

  DateTime queryDateFor(DateTime start, int offsetDays) {
    // 查询日期自带固定的非零时分，用于验证 normalize 到整天后的行为。
    final base = DateTime(
      start.year,
      start.month,
      start.day,
    ).add(Duration(days: offsetDays, hours: 13, minutes: 37));
    return base;
  }

  /// 参考模型：第 1 周从开学日所在周的周一起算（课表网格以周一为一周起点）。
  DateTime weekOneFor(DateTime start) {
    final startDay = DateTime(start.year, start.month, start.day);
    return startDay.subtract(Duration(days: startDay.weekday - 1));
  }

  int expectedWeekFor(DateTime start, DateTime query) {
    final diff = DateTime(
      query.year,
      query.month,
      query.day,
    ).difference(weekOneFor(start)).inDays;
    return diff < 0 ? 1 : (diff ~/ 7 + 1).clamp(1, semesterWeeks);
  }

  group('SemesterCalendar 周数计算不变量', () {
    test('weekOneStartDate 恒为周一，且与开学日在同一周', () async {
      final calendar = SemesterCalendar.instance;
      await forAll('第 1 周起点是开学日所在周的周一', startGen, (DateTime start) async {
        await calendar.setSemesterStartDate(start);
        final weekOne = calendar.weekOneStartDate;
        expect(weekOne.weekday, DateTime.monday);
        final startDay = DateTime(start.year, start.month, start.day);
        expect(
          startDay.difference(weekOne).inDays,
          inInclusiveRange(0, 6),
          reason: 'start=$start',
        );
      });
    });

    test('weekForDate 与周一对齐的参考模型完全一致', () async {
      final calendar = SemesterCalendar.instance;
      await forAll(
        '任意开学日/日期组合下，周数等于钳制后的 (距第 1 周周一的天数 ~/ 7) + 1',
        startWithOffset(),
        (values) async {
          final (start, offset) = values;
          await calendar.setSemesterStartDate(start);
          final date = queryDateFor(start, offset);
          final week = calendar.weekForDate(date);
          expect(week, expectedWeekFor(start, date), reason: 'offset=$offset');
          expect(
            week,
            inInclusiveRange(1, semesterWeeks),
            reason: 'offset=$offset',
          );
        },
      );
    });

    test('weekForDate 随日期单调不减且单次推进幅度不超过 1', () async {
      final calendar = SemesterCalendar.instance;
      await forAll('日期每推进一天周数最多加 1，且从不回退', startWithOffset(), (values) async {
        final (start, offset) = values;
        await calendar.setSemesterStartDate(start);
        final before = calendar.weekForDate(queryDateFor(start, offset));
        final after = calendar.weekForDate(queryDateFor(start, offset + 1));
        expect(after, greaterThanOrEqualTo(before));
        expect(after - before, inInclusiveRange(0, 1));
      });
    });

    test('一周内（1-6 天内）的日期周数不变或恰好跨入下一周', () async {
      final calendar = SemesterCalendar.instance;
      final startOffsetShiftGen = pair(
        startGen,
        pair(intsInRange(-90, 220), intsInRange(1, 6)),
      );
      await forAll('同一天加上 1-6 天，周数差不超过 1', startOffsetShiftGen, (values) async {
        final (start, (offset, shift)) = values;
        await calendar.setSemesterStartDate(start);
        final week = calendar.weekForDate(queryDateFor(start, offset));
        final shiftedWeek = calendar.weekForDate(
          queryDateFor(start, offset + shift),
        );
        expect(shiftedWeek - week, inInclusiveRange(0, 1));
      });
    });

    test(
      'isBeforeSemesterStart 以第 1 周周一为界，isAfterSemesterEnd 以开学日+140 天为界',
      () async {
        final calendar = SemesterCalendar.instance;
        await forAll('开学前/教学周内/结课后恰好覆盖所有日期', startWithOffset(), (values) async {
          final (start, offset) = values;
          await calendar.setSemesterStartDate(start);
          final date = queryDateFor(start, offset);

          final dateDay = DateTime(date.year, date.month, date.day);
          final startDay = DateTime(start.year, start.month, start.day);
          final daysSinceStart = dateDay.difference(startDay).inDays;

          expect(
            calendar.isBeforeSemesterStart(date),
            dateDay.isBefore(weekOneFor(start)),
            reason: 'offset=$offset',
          );
          expect(
            calendar.isAfterSemesterEnd(date),
            daysSinceStart >= semesterTotalDays,
            reason: 'offset=$offset',
          );
          // 假期标志位互斥，且只要落在教学周内，周数必然有效。
          expect(
            calendar.isBeforeSemesterStart(date) &&
                calendar.isAfterSemesterEnd(date),
            isFalse,
          );
          if (!calendar.isBeforeSemesterStart(date) &&
              !calendar.isAfterSemesterEnd(date)) {
            final week = calendar.weekForDate(date);
            expect(week, inInclusiveRange(1, semesterWeeks));
          }
        });
      },
    );

    test('weekStartFor 与 weekForDate 互逆：第 k 周周一查询得到第 k 周', () async {
      final calendar = SemesterCalendar.instance;
      await forAll('weekStartFor(k) 反查回 k', startWithOffset(), (values) async {
        final (start, offset) = values;
        await calendar.setSemesterStartDate(start);
        final week = expectedWeekFor(start, queryDateFor(start, offset));
        final monday = calendar.weekStartFor(week);
        expect(calendar.weekForDate(monday), week, reason: 'offset=$offset');
      });
    });
  });

  group('SemesterCalendar.defaultSemesterStartFor 默认开学日规则', () {
    test('任意日期都按 秋季 9-1 / 春季 3-2 规则推导', () {
      final dateGen = dateTimesNear(
        DateTime(2025, 6, 1),
        minOffsetDays: -800,
        maxOffsetDays: 800,
      );
      forAll('8-1 月默认 9 月 1 日，2-7 月默认当年 3 月 2 日（1-2 月取上一学年）', dateGen, (
        DateTime date,
      ) {
        final start = SemesterCalendar.defaultSemesterStartFor(date);
        if (date.month >= 8) {
          expect(start, DateTime(date.year, 9, 1));
        } else if (date.month <= 2) {
          expect(start, DateTime(date.year - 1, 9, 1));
        } else {
          expect(start, DateTime(date.year, 3, 2));
        }
      });
    });
  });
}
