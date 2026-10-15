import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_sync_control.dart';
import 'package:jxu_campus_hub/features/settings/calendar_legacy_cleanup_dialog.dart';

import '../helpers/preview_support.dart';

/// 遗留清理预览（Issue #48）的视觉渲染（预渲染脚本）。
///
/// 默认 `flutter test` 全部 skip（零副作用、不写任何 golden）；由
/// `tools/render_previews.ps1` 设置 `JXU_PREVIEW_RENDER=1` 并配合
/// `flutter test --update-goldens test/preview/calendar_legacy_cleanup_preview_test.dart`
/// 渲染为 `preview/render/*.png`（该目录已 gitignore，PNG 不入库）。
///
/// 场景数据全部为**合成**数量与展示名：不含真实课程 / 学号 / 日历 id / opaqueId。
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    // 字体加载依赖真实事件循环，必须在 FakeAsync 之外完成。
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  void previewTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await body(tester);
    }, skip: !renderEnabled);
  }

  Future<void> renderScene(
    WidgetTester tester,
    String name,
    CalendarLegacyCleanupScan scan, {
    Brightness brightness = Brightness.light,
  }) async {
    await pumpPreviewScene(
      tester,
      (_) => Scaffold(
        body: const SizedBox.expand(),
        bottomSheet: CalendarLegacyCleanupPreviewSheet(scan: scan),
      ),
      brightness: brightness,
    );
    await expectPreviewGolden(tester, name);
  }

  previewTest('calendar_legacy_cleanup_preview_light', (tester) async {
    await renderScene(
      tester,
      'calendar_legacy_cleanup_preview_light',
      _completeScan(),
    );
  });

  previewTest('calendar_legacy_cleanup_preview_dark', (tester) async {
    await renderScene(
      tester,
      'calendar_legacy_cleanup_preview_dark',
      _completeScan(),
      brightness: Brightness.dark,
    );
  });

  previewTest('calendar_legacy_cleanup_preview_partial_light', (tester) async {
    await renderScene(
      tester,
      'calendar_legacy_cleanup_preview_partial_light',
      _partialScan(),
    );
  });
}

/// 完整扫描：两个可写日历（一个含已记账 + 孤儿，一个仅孤儿）。
CalendarLegacyCleanupScan _completeScan() => const CalendarLegacyCleanupScan(
  token: 'preview-complete',
  calendars: <CalendarLegacyCleanupCalendarPreview>[
    CalendarLegacyCleanupCalendarPreview(
      calendarId: 1,
      displayName: '课程日历',
      writable: true,
      recordedCount: 12,
      orphanCount: 2,
      ownedCount: 14,
    ),
    CalendarLegacyCleanupCalendarPreview(
      calendarId: 2,
      displayName: '第二个日历（名称较长，用于验证窄屏换行）',
      writable: true,
      recordedCount: 0,
      orphanCount: 4,
      ownedCount: 4,
    ),
  ],
  complete: true,
  reason: null,
  totalKnownOwnedCount: 18,
  recordedOrphanCount: 6,
  dismissible: false,
  candidates: <LegacyCleanupCandidate>[],
);

/// 不完整扫描：一个只读日历 + 一个归属未知日历（都不能清理）。
CalendarLegacyCleanupScan _partialScan() => const CalendarLegacyCleanupScan(
  token: 'preview-partial',
  calendars: <CalendarLegacyCleanupCalendarPreview>[
    CalendarLegacyCleanupCalendarPreview(
      calendarId: 3,
      displayName: '只读共享日历',
      writable: false,
      recordedCount: 3,
      orphanCount: 1,
      ownedCount: 4,
    ),
    CalendarLegacyCleanupCalendarPreview(
      calendarId: 4,
      displayName: null,
      writable: null,
      recordedCount: 0,
      orphanCount: 0,
      ownedCount: 0,
    ),
  ],
  complete: false,
  reason: CalendarLegacyCleanupFailure.scanLimit,
  totalKnownOwnedCount: 4,
  recordedOrphanCount: 1,
  dismissible: false,
  candidates: <LegacyCleanupCandidate>[],
);
