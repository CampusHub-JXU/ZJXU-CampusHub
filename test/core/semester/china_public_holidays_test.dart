import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/semester/china_public_holidays.dart';

void main() {
  test('2026 国庆 10/1-10/7 闭区间', () {
    expect(chinaPublicHolidayOn(DateTime(2026, 9, 30)), isNull);
    expect(chinaPublicHolidayOn(DateTime(2026, 10, 1))?.name, '国庆节');
    expect(chinaPublicHolidayOn(DateTime(2026, 10, 7, 23, 59))?.name, '国庆节');
    expect(chinaPublicHolidayOn(DateTime(2026, 10, 8)), isNull);
  });

  test('调休上班日不算假期', () {
    expect(chinaPublicHolidayOn(DateTime(2026, 9, 20)), isNull);
    expect(chinaPublicHolidayOn(DateTime(2026, 10, 10)), isNull);
  });

  test('未收录年份不猜测', () {
    expect(chinaPublicHolidayOn(DateTime(2027, 10, 1)), isNull);
  });
}
