import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/home/models/example_campus_snapshot.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_projection.dart';

void main() {
  test('fromPresentation 生成无凭据投影并可序列化', () {
    final generatedAt = DateTime(2026, 9, 12, 8, 30);
    final projection = CampusWidgetProjection.fromPresentation(
      ExampleCampusSnapshot.presentation,
      generatedAt: generatedAt,
      unreadNoticeCount: 3,
    );

    expect(projection.hasTodayCourses, isTrue);
    expect(projection.todayCourses, isNotEmpty);
    expect(projection.heroCourseName, '高等数学 C2');
    expect(projection.hasCampusCardData, isTrue);
    expect(projection.campusCardBalance, isNotEmpty);
    expect(projection.unreadNoticeCount, 3);

    final map = projection.toMap();
    expect(map['generatedAt'], generatedAt.toIso8601String());
    expect(map['todayTitle'], isNotEmpty);
    expect(
      (map['todayCourses'] as List),
      hasLength(projection.todayCourses.length),
    );

    final keys = map.keys.join(',').toLowerCase();
    for (final secret in const [
      'cookie',
      'token',
      'password',
      'session',
      'credential',
    ]) {
      expect(keys.contains(secret), isFalse, reason: '投影不得包含凭据字段: $secret');
    }
  });
}
