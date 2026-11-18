import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_page.dart';
import 'package:jxu_campus_hub/features/library/library_borrows_page.dart';
import 'package:jxu_campus_hub/features/library/library_session.dart';
import 'package:jxu_campus_hub/features/library/library_token_reader.dart';

import '../helpers/mock_http_client_adapter.dart';
import '../helpers/preview_support.dart';
import '../helpers/test_setup.dart';

/// Issue #51 —— 分段控件外观「调整前后」在**真实页面**上的对比预览。
///
/// 与 `preview_render_test.dart` 的 `segmented_controls_*` 不同：那是一个复刻
/// 配置的**合成场景**，本文件渲染的是**真实的 `GradesPage` / `LibraryBorrowsPage`
/// 类**（用既有 service 注入缝 + 合成 fixture，无真实账号 / 网络），只切换主题：
/// * `before`：`ThemeData.copyWith(segmentedButtonTheme: const SegmentedButtonThemeData())`
///   —— 等价于改动前「主题里没有 `segmentedButtonTheme`」的 MD3 默认外观；
/// * `after`：当前 `AppThemeBuilder`（含本次主题级 `segmentedButtonTheme`）。
///
/// 每个用例只装载**一种**主题，绝不在同一棵树上换主题：`SegmentedButton` 的
/// `AnimatedDefaultTextStyle` 会在主题切换时尝试在两个 `TextStyle`（`inherit` 不同）
/// 之间插值并抛断言——那是「换主题」这一预览动作的产物，不是生产路径（生产里
/// 浅/深主题同源，`textStyle` 状态无关、不会触发该插值）。
///
/// 输出到被 gitignore 的 `output/issue51/raw/segmented-actual/{before,after}/`，
/// 与 `preview/render/` 一样是**本地渲染产物**、不随 PR 提交。
///
/// 默认 `flutter test` 整体 skip（零副作用）；渲染：
///   `$env:JXU_PREVIEW_RENDER=1; flutter test test/preview/segmented_actual_pages_preview_test.dart --update-goldens`
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  const outputBase = '../../output/issue51/raw/segmented-actual';

  ThemeData newLight() => previewTheme(AppThemeBuilder.light(kPreviewSeed));
  ThemeData newDark() => previewTheme(AppThemeBuilder.dark(kPreviewSeed));
  // 改动前：主题里没有 segmentedButtonTheme（ThemeData 默认即空的
  // SegmentedButtonThemeData），SegmentedButton 回落到 MD3 默认样式。
  ThemeData oldLight() => newLight().copyWith(
    segmentedButtonTheme: const SegmentedButtonThemeData(),
  );
  ThemeData oldDark() => newDark().copyWith(
    segmentedButtonTheme: const SegmentedButtonThemeData(),
  );

  ThemeData themeFor(String variant, Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    if (variant == 'before') return dark ? oldDark() : oldLight();
    return dark ? newDark() : newLight();
  }

  /// 有界泵：不 pumpAndSettle，避免页面内一次性入场动画在 fake-async 下卡住；
  /// 真实数据由注入缝同步返回，故泵固定帧数即可落定。
  Future<void> pumpActualPage(
    WidgetTester tester,
    Widget page,
    ThemeData theme, {
    int frames = 12,
  }) async {
    tester.view.devicePixelRatio = kPreviewDpr;
    tester.view.physicalSize = Size(
      kPreviewLogicalSize.width * kPreviewDpr,
      kPreviewLogicalSize.height * kPreviewDpr,
    );
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(debugShowCheckedModeBanner: false, theme: theme, home: page),
    );
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 真实异步解码 / 微任务跑一拍（与 preview_support 一致）。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump();
  }

  Future<void> render(
    WidgetTester tester,
    String name,
    Widget page,
    ThemeData theme,
  ) async {
    await pumpActualPage(tester, page, theme);
    // 不得忽略页面真实异常。
    expect(tester.takeException(), isNull, reason: name);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$outputBase/$name.png'),
    );
  }

  // ── 真实成绩页：分段在顶部（课程成绩 / 学业进度），惰性激活不变 ────────────
  Widget gradesPage() => GradesPage(
    fetchGrades: (_, {bool forceRefresh = false}) async => <GradeEntry>[
      GradeEntry.fromJson(<String, dynamic>{
        'kcmc': '高等数学 B',
        'cj': '92',
        'bfzcj': '92',
        'jd': '4.0',
        'xf': '4.5',
        'xnmmc': '2025-2026',
        'xqmmc': '第二学期',
      }),
      GradeEntry.fromJson(<String, dynamic>{
        'kcmc': '数据结构',
        'cj': '88',
        'bfzcj': '88',
        'jd': '3.7',
        'xf': '4.0',
        'xnmmc': '2025-2026',
        'xqmmc': '第二学期',
      }),
      GradeEntry.fromJson(<String, dynamic>{
        'kcmc': '大学英语',
        'cj': '85',
        'bfzcj': '85',
        'jd': '3.5',
        'xf': '3.0',
        'xnmmc': '2025-2026',
        'xqmmc': '第一学期',
      }),
    ],
  );

  for (final brightness in Brightness.values) {
    for (final variant in const <String>['before', 'after']) {
      testWidgets(
        'preview: actual grades page ($variant, ${brightness.name})',
        (tester) async {
          if (!renderEnabled) return;
          await resetTestEnvironment();
          ZhengfangAuth.instance.debugSetSession(
            active: true,
            studentId: '20250001',
          );
          await render(
            tester,
            '$variant/actual_grades_${brightness.name}',
            gradesPage(),
            themeFor(variant, brightness),
          );
        },
        skip: !renderEnabled,
      );
    }
  }

  // ── 真实图书馆借阅页：分段（借阅中 / 历史借阅），经既有 Dio mock 注入缝 ───
  Future<void> seedLibrary() async {
    await resetTestEnvironment();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'PREVIEW_LIB_ACCOUNT',
    );
    LibrarySession.instance.debugReset();
    LibraryTokenReader.debugReadOverride = (url) async => 'preview-token';
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();

    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/user/borrows', <String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'bookName': '高等数学',
          'author': '同济大学数学系',
          'desc': 'O13/68 · 高等教育出版社',
          'borrowTime': '2026-03-01 09:12:00',
          'endTime': '2026年06月01日',
          'infoDay': 2,
          'renewID': 'R2026',
        },
        <String, Object?>{
          'bookName': '数据结构与算法分析',
          'author': 'Mark Allen Weiss',
          'desc': 'TP311/88 · 机械工业出版社',
          'borrowTime': '2026-02-20 14:03:00',
          'endTime': '2026年05月20日',
          'infoDay': 6,
          'renewID': 'R2027',
        },
      ],
      'page': 1,
      'pageSize': 100,
      'nextUrl': '',
    });
    DioClient.instance.dio.httpClientAdapter = adapter;
  }

  tearDown(() {
    LibraryTokenReader.debugReadOverride = null;
    LibrarySession.instance.debugReset();
  });

  for (final brightness in Brightness.values) {
    for (final variant in const <String>['before', 'after']) {
      testWidgets(
        'preview: actual library borrows page ($variant, ${brightness.name})',
        (tester) async {
          if (!renderEnabled) return;
          await seedLibrary();
          await render(
            tester,
            '$variant/actual_library_${brightness.name}',
            const LibraryBorrowsPage(),
            themeFor(variant, brightness),
          );
        },
        skip: !renderEnabled,
      );
    }
  }
}
