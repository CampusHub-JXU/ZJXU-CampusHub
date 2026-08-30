import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';

void main() {
  test('功能入口配置包含生产展示与路由所需字段并保持排序', () {
    final entries = AppFeaturesConfig.entries;
    final library = entries.firstWhere((entry) => entry.id == 'library');
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
        20,
        25,
        30,
        40,
        42,
        45,
        50,
        55,
        60,
        65,
        70,
      ]),
    );
    expect(library.title, '图书馆');
    expect(library.subtitle, isNotEmpty);
    expect(library.routeName, 'library');
    expect(library.icon, Icons.local_library_outlined);
    expect(library.accentColor, AppColors.info);
    expect(changxing.accentColor, const Color(0xFF2EA567));
  });
}
