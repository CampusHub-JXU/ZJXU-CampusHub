import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/cache/json_cache_store.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_cache_store.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';

const _catalog = SecondClassroomCatalog(
  categories: [SecondClassroomFilterOption(value: '1', text: '思想成长')],
  departments: [SecondClassroomFilterOption(value: '51', text: '建工学院')],
  organizationTypes: [SecondClassroomFilterOption(value: '2', text: '学生部门')],
);

void main() {
  Directory? tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('second_classroom_cache');
    JsonCacheStore.instance.debugDirectoryProvider = () async => tempDir!;
  });

  tearDown(() async {
    await JsonCacheStore.instance.debugClear();
    JsonCacheStore.instance.debugReset();
    tempDir?.deleteSync(recursive: true);
    tempDir = null;
  });

  test('stores catalog and activity cache by query bucket', () async {
    final store = SecondClassroomCacheStore.instance;
    await store.debugClear();

    await store.saveCatalog(_catalog);

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

  test('JsonCacheStore.clearAll 同时清空第二课堂目录与活动缓存', () async {
    final store = SecondClassroomCacheStore.instance;
    const query = SecondClassroomActivityQuery(categoryId: '1');
    await store.saveCatalog(_catalog);
    await store.saveActivities(query, [_activity]);
    expect(await store.loadCatalog(), isNotNull);
    expect(await store.loadActivities(query), isNotNull);

    await JsonCacheStore.instance.clearAll();

    expect(await store.loadCatalog(), isNull);
    expect(await store.loadActivities(query), isNull);
  });

  test('活动缓存最多保留 12 个查询桶，淘汰最旧的', () async {
    final store = SecondClassroomCacheStore.instance;
    for (var i = 1; i <= 13; i++) {
      await store.saveActivities(
        SecondClassroomActivityQuery(categoryId: '$i'),
        [_activity],
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    expect(
      await store.loadActivities(
        const SecondClassroomActivityQuery(categoryId: '1'),
      ),
      isNull,
    );
    expect(
      await store.loadActivities(
        const SecondClassroomActivityQuery(categoryId: '13'),
      ),
      isNotNull,
    );
  });

  test('首次使用时清除迁移前遗留的 SharedPreferences 旧键', () async {
    final store = SecondClassroomCacheStore.instance;
    // debugClear 会重置「已清除旧键」的一次性标记。
    await store.debugClear();
    SharedPreferences.setMockInitialValues({
      'second_classroom_catalog_cache_v1': '{"categories":[]}',
      'second_classroom_activity_cache_v1': '{}',
    });

    expect(await store.loadCatalog(), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('second_classroom_catalog_cache_v1'), isFalse);
    expect(prefs.containsKey('second_classroom_activity_cache_v1'), isFalse);
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
