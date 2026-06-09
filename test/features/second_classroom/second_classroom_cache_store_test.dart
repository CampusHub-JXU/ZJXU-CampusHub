import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_cache_store.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores catalog and activity cache by query bucket', () async {
    final store = SecondClassroomCacheStore.instance;
    await store.debugClear();

    const catalog = SecondClassroomCatalog(
      categories: [SecondClassroomFilterOption(value: '1', text: '思想成长')],
      departments: [SecondClassroomFilterOption(value: '51', text: '建工学院')],
      organizationTypes: [
        SecondClassroomFilterOption(value: '2', text: '学生部门'),
      ],
    );
    await store.saveCatalog(catalog);

    const firstQuery = SecondClassroomActivityQuery(categoryId: '1');
    const secondQuery = SecondClassroomActivityQuery(categoryId: '3');
    await store.saveActivities(firstQuery, [_activity]);

    final cachedCatalog = await store.loadCatalog();
    final firstSnapshot = await store.loadActivities(firstQuery);
    final secondSnapshot = await store.loadActivities(secondQuery);

    expect(cachedCatalog?.categories.single.text, '思想成长');
    expect(firstSnapshot?.activities.single.id, 2485);
    expect(firstSnapshot?.updatedAt, isNotNull);
    expect(secondSnapshot, isNull);
  });
}

final _activity = SecondClassroomActivity(
  id: 2485,
  title: '榜样分享活动',
  coverId: 'cover-id',
  iconId: 'icon-id',
  registrationStartAt: DateTime(2026, 6, 9, 10),
  registrationEndAt: DateTime(2026, 6, 9, 14),
  activityStartAt: DateTime(2026, 6, 9, 16),
  activityEndAt: DateTime(2026, 6, 9, 17),
  creditHours: 0,
  location: '兴德楼北楼201',
  summary: '报名成功后加群',
  contactName: '张展健',
  contactPhone: '18536419261',
  categoryName: '思想成长',
  organizerName: '建工学院团委学生会',
  capacity: 90,
  enrolledCount: 31,
  isRegistered: false,
  hasCheckedIn: false,
  hasRetaken: false,
);
