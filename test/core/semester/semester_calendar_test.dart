import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('normalizes stored start date and persists manual changes', () async {
    final calendar = SemesterCalendar.instance;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'semester_start_date_millis',
      DateTime(2026, 3, 1, 14, 30).millisecondsSinceEpoch,
    );

    await calendar.init();
    expect(calendar.semesterStartDate.value, DateTime(2026, 3, 1));

    await calendar.setSemesterStartDate(DateTime(2026, 3, 8, 23, 59));
    expect(calendar.semesterStartDate.value, DateTime(2026, 3, 8));
    expect(
      prefs.getInt('semester_start_date_millis'),
      DateTime(2026, 3, 8).millisecondsSinceEpoch,
    );
  });

  test('weekForDate clamps within 1 to 20', () async {
    final calendar = SemesterCalendar.instance;
    await calendar.setSemesterStartDate(DateTime(2026, 3, 2));

    expect(calendar.weekForDate(DateTime(2026, 2, 20)), 1);
    expect(calendar.weekForDate(DateTime(2026, 3, 2, 23, 59)), 1);
    expect(calendar.weekForDate(DateTime(2026, 3, 9)), 2);
    expect(calendar.weekForDate(DateTime(2026, 8, 30)), 20);
  });

  test(
    'isBeforeSemesterStart and isAfterSemesterEnd flag vacation windows',
    () async {
      final calendar = SemesterCalendar.instance;
      await calendar.setSemesterStartDate(DateTime(2026, 3, 2));

      expect(calendar.isBeforeSemesterStart(DateTime(2026, 3, 1)), isTrue);
      expect(calendar.isBeforeSemesterStart(DateTime(2026, 3, 2)), isFalse);
      expect(calendar.isBeforeSemesterStart(DateTime(2026, 7, 15)), isFalse);

      expect(calendar.isAfterSemesterEnd(DateTime(2026, 7, 15)), isFalse);
      expect(calendar.isAfterSemesterEnd(DateTime(2026, 7, 20)), isTrue);
      expect(calendar.isAfterSemesterEnd(DateTime(2026, 7, 19)), isFalse);
    },
  );

  test('week start snaps to the Monday of the semester start week', () async {
    final calendar = SemesterCalendar.instance;
    // 2026-09-01 是周二，第 1 周应从 8/31（周一）起算。
    await calendar.setSemesterStartDate(DateTime(2026, 9, 1));

    expect(calendar.weekOneStartDate, DateTime(2026, 8, 31));
    expect(calendar.weekStartFor(1), DateTime(2026, 8, 31));
    expect(calendar.weekStartFor(2), DateTime(2026, 9, 7));

    expect(calendar.weekForDate(DateTime(2026, 8, 31)), 1);
    expect(calendar.weekForDate(DateTime(2026, 9, 6)), 1);
    expect(calendar.weekForDate(DateTime(2026, 9, 7)), 2);

    expect(calendar.isBeforeSemesterStart(DateTime(2026, 8, 30)), isTrue);
    expect(calendar.isBeforeSemesterStart(DateTime(2026, 8, 31)), isFalse);
  });
}
