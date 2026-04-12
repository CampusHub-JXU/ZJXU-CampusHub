import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jiaxing_university_portal/app/theme.dart';
import 'package:jiaxing_university_portal/core/config/feature_entry_catalog.dart';

void main() {
  group('FeatureEntryCatalog', () {
    test('parses yaml entries into resolved feature definitions', () {
      final entries = FeatureEntryCatalog.instance.parse('''
entries:
  - id: library
    title: 图书馆
    subtitle: 馆藏检索
    icon: local_library_outlined
    color: info
    route: library
    span:
      compact:
        columns: 2
        rows: 1
      expanded:
        columns: 2
        rows: 1
    placements:
      - service_hub
      - home_learning
    sort: 20
  - id: grades
    title: 成绩查询
    subtitle: 查看成绩
    icon: school_outlined
    color: warning
    route: grades
    span:
      compact:
        columns: 1
        rows: 1
      expanded:
        columns: 1
        rows: 1
    placements:
      - service_hub
    sort: 30
''');

      expect(entries, hasLength(2));

      final library = entries.first;
      expect(library.id, 'library');
      expect(library.title, '图书馆');
      expect(library.routeName, 'library');
      expect(library.icon, Icons.local_library_outlined);
      expect(library.accentColor, AppColors.info);
      expect(library.cardType, FeatureEntryCardType.wideRect);
      expect(library.span.columns, 2);
      expect(library.span.rows, 1);
      expect(library.spanForGridColumns(2).columns, 2);
      expect(library.spanForGridColumns(2).rows, 1);
      expect(
        library.placements,
        containsAll(<FeatureEntryPlacement>[
          FeatureEntryPlacement.serviceHub,
          FeatureEntryPlacement.homeLearning,
        ]),
      );
    });

    test('supports hex colors in yaml config', () {
      final entries = FeatureEntryCatalog.instance.parse('''
entries:
  - id: changxing-jiada
    title: 畅行嘉大
    subtitle: 请假与返校
    icon: north_rounded
    color: "#2EA567"
    route: changxing-jiada
    span:
      compact:
        columns: 2
        rows: 1
      expanded:
        columns: 1
        rows: 2
    placements:
      - home_learning
''');

      expect(entries.single.accentColor, const Color(0xFF2EA567));
    });

    test('rejects unsupported span sizes', () {
      expect(
        () => FeatureEntryCatalog.instance.parse('''
entries:
  - id: service-hall
    title: 服务大厅
    subtitle: 统一入口
    icon: dashboard_customize_outlined
    color: primary
    route: service-hall
    span:
      compact:
        columns: 3
        rows: 1
      expanded:
        columns: 2
        rows: 2
    placements:
      - service_hub
'''),
        throwsFormatException,
      );
    });

    test('supports legacy single span config', () {
      final entries = FeatureEntryCatalog.instance.parse('''
entries:
  - id: grades
    title: 成绩查询
    subtitle: 查看成绩
    icon: school_outlined
    color: warning
    route: grades
    span:
      columns: 2
      rows: 1
    placements:
      - service_hub
''');

      expect(entries.single.cardType, FeatureEntryCardType.wideRect);
      expect(entries.single.spanForGridColumns(2).columns, 2);
      expect(entries.single.spanForGridColumns(4).columns, 2);
    });
  });
}
