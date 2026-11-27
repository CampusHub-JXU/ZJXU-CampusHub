import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_model.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_page.dart';

import '../../helpers/preview_support.dart';
import '../../helpers/test_setup.dart';

/// 体测成绩页视觉预览（本地、按需）：只渲染 [PhysicalTestPage] 的合成脱敏状态，
/// 产出亮 / 暗两种手机尺寸截图，供维护者肉眼比对总分是否一眼可见、单项是否拥挤。
///
/// `flutter test` 默认整体 skip，零副作用；由手动入口运行：
///   $env:JXU_PREVIEW_RENDER=1
///   flutter test --update-goldens test/features/physical_test/physical_test_preview_test.dart
///
/// 产物落在仓库根 `preview/render/`（gitignored）。字体用本机运行时中文字体
/// （见 preview_support），不打包、不新增依赖。**这些截图是渲染预览，不是设备
/// 端到端验收**；真机观感仍需人工在真机 / 模拟器上复核。
const String _goldenDir = '../../../preview/render';

PhysicalTestSnapshot _multiYear() => PhysicalTestSnapshot(
  records: [
    PhysicalTestRecord(
      academicYear: '2025-2026',
      totalScore: '86.5',
      grade: '良好',
      items: const [
        PhysicalTestItem(
          name: '50 米跑',
          result: '7.2 秒',
          score: '90',
          level: '优秀',
        ),
        PhysicalTestItem(
          name: '立定跳远',
          result: '2.35 米',
          score: '83',
          level: '良好',
        ),
        PhysicalTestItem(
          name: '坐位体前屈',
          result: '12.5 厘米',
          score: '76',
          level: '及格',
        ),
        PhysicalTestItem(
          name: '1000 米跑',
          result: '4 分 05 秒',
          score: '72.5',
          level: '及格',
        ),
        PhysicalTestItem(
          name: '肺活量',
          result: '4123.5 毫升',
          score: '88',
          level: '良好',
        ),
      ],
    ),
    PhysicalTestRecord(
      academicYear: '2024-2025',
      totalScore: '78',
      grade: '及格',
      items: const [
        PhysicalTestItem(
          name: '50 米跑',
          result: '7.6 秒',
          score: '80',
          level: '良好',
        ),
        PhysicalTestItem(name: '立定跳远', result: '2.18 米', score: '72'),
      ],
    ),
    const PhysicalTestRecord(academicYear: '2023-2024'),
  ],
);

PhysicalTestSnapshot _singleYear() => PhysicalTestSnapshot(
  records: [
    PhysicalTestRecord(
      academicYear: '2025-2026',
      totalScore: '86.5',
      grade: '良好',
      items: const [
        PhysicalTestItem(
          name: '50 米跑',
          result: '7.2 秒',
          score: '90',
          level: '优秀',
        ),
        PhysicalTestItem(name: '立定跳远', result: '2.35 米', score: '83'),
      ],
    ),
  ],
);

/// 缺总分 / 缺等级 / 无项目 / 非数字与长单位混合的边界形态。
PhysicalTestSnapshot _edge() => PhysicalTestSnapshot(
  records: [
    const PhysicalTestRecord(academicYear: '2025-2026'),
    PhysicalTestRecord(
      academicYear: '2024-2025',
      totalScore: '免测',
      grade: '免测',
      items: const [
        PhysicalTestItem(name: '肺活量', result: '4123.5 毫升'),
        PhysicalTestItem(name: '引体向上', result: '未参加', level: '免测'),
        PhysicalTestItem(
          name: '这是一个特别特别长的体测项目名称用于验证窄屏不溢出',
          result: '4 分 05 秒',
          score: '72.5',
        ),
      ],
    ),
  ],
);

void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  void previewTest(String name, PhysicalTestSnapshot snapshot, Brightness b) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await resetTestEnvironment();
      await pumpPreviewScene(
        tester,
        (_) => PhysicalTestPage(snapshotFetcher: () async => snapshot),
        brightness: b,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$_goldenDir/$name.png'),
      );
    }, skip: !renderEnabled);
  }

  previewTest('physical_test_multi_light', _multiYear(), Brightness.light);
  previewTest('physical_test_multi_dark', _multiYear(), Brightness.dark);
  previewTest('physical_test_single_light', _singleYear(), Brightness.light);
  previewTest('physical_test_edge_light', _edge(), Brightness.light);

  for (final (name, b) in [
    ('physical_test_calc_light', Brightness.light),
    ('physical_test_calc_dark', Brightness.dark),
  ]) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await resetTestEnvironment();
      final fullSnapshot = PhysicalTestSnapshot(
        records: [
          PhysicalTestRecord(
            academicYear: '2025-2026',
            totalScore: '84.6',
            grade: '良好',
            items: const [
              PhysicalTestItem(name: '身高', result: '176.0 厘米'),
              PhysicalTestItem(name: '体重', result: '66.0 公斤'),
              PhysicalTestItem(name: '肺活量', result: '4650 毫升'),
              PhysicalTestItem(name: '50米跑', result: '7.1 秒'),
              PhysicalTestItem(name: '坐体前屈', result: '18.5 厘米'),
              PhysicalTestItem(name: '立定跳远', result: '248 厘米'),
              PhysicalTestItem(name: '引体向上', result: '15 个'),
              PhysicalTestItem(name: '1000米跑', result: '3.48 分钟'),
            ],
          ),
        ],
      );
      await pumpPreviewScene(
        tester,
        (_) => PhysicalTestPage(snapshotFetcher: () async => fullSnapshot),
        brightness: b,
      );
      await tester.tap(find.text('成绩计算'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('请选择年级'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大三'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$_goldenDir/$name.png'),
      );
    }, skip: !renderEnabled);
  }
}
