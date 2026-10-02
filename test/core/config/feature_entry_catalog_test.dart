import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/actions/campus_action_ids.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';
import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';

void main() {
  test('功能入口配置包含生产展示与路由所需字段并保持排序', () {
    final entries = AppFeaturesConfig.entries;
    final library = entries.firstWhere((entry) => entry.id == 'library');
    final secondClassroom = entries.firstWhere(
      (entry) => entry.id == 'second-classroom',
    );
    final changxing = entries.firstWhere(
      (entry) => entry.id == 'changxing-jiada',
    );

    expect(entries, AppFeaturesConfig.entries);
    expect(
      entries.map((entry) => entry.sortOrder),
      orderedEquals(<int>[
        5,
        10,
        15,
        17,
        20,
        25,
        30,
        40,
        42,
        45,
        50,
        55,
        60,
        70,
        75,
        80,
        85,
      ]),
    );
    expect(library.title, '图书馆');
    expect(library.subtitle, isNotEmpty);
    expect(library.primaryActionId, CampusActionIds.libraryOpen);
    expect(library.icon, Icons.local_library_outlined);
    expect(library.accentColor, AppColors.info);
    expect(
      secondClassroom.primaryActionId,
      CampusActionIds.secondClassroomOpen,
    );
    expect(changxing.primaryActionId, CampusActionIds.changxingJiadaOpen);
    expect(changxing.accentColor, const Color(0xFF2EA567));
    final physicalTest = entries.firstWhere(
      (entry) => entry.id == 'physical-test',
    );
    expect(physicalTest.title, '体测成绩');
    expect(physicalTest.primaryActionId, CampusActionIds.physicalTestOpen);
  });

  test('每个功能入口都归入一个分类，搜索别名不为空白', () {
    for (final entry in AppFeaturesConfig.entries) {
      expect(FeatureEntryCategory.values, contains(entry.category));
      for (final keyword in entry.keywords) {
        expect(keyword.trim(), isNotEmpty, reason: entry.id);
      }
    }
    expect(
      AppFeaturesConfig.entries.map((entry) => entry.category).toSet(),
      FeatureEntryCategory.values.toSet(),
    );
  });
}
