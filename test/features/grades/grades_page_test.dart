import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_page.dart';
import 'package:jxu_campus_hub/features/grades/grades_term_resolver.dart';
import 'package:jxu_campus_hub/features/grades/widgets/grades_grade_card.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250001');
  });

  Future<void> pumpGradesPage(
    WidgetTester tester, {
    required List<Map<String, dynamic>> items,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradesPage(
            fetchGrades: (_, {bool forceRefresh = false}) async =>
                items.map(GradeEntry.fromJson).toList(),
          ),
        ),
      ),
    );
    // Do not use pumpAndSettle: the page owns stagger/size animations and the
    // Linux coverage runner may keep scheduling frames. Also do not assume the
    // mocked Dio request finishes within a fixed number of pumps. Wait for the
    // first data-backed widget with a hard fake-time bound, then finish the
    // known 420ms entrance animation.
    for (
      var elapsed = Duration.zero;
      elapsed < const Duration(seconds: 5) &&
          find.byType(AppDropdown<String>).evaluate().isEmpty;
      elapsed += const Duration(milliseconds: 50)
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byType(AppDropdown<String>),
      findsOneWidget,
      reason: '成绩请求应在 5 秒测试时间内完成并渲染学期下拉框',
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  Map<String, dynamic> grade(
    String course,
    String year,
    String semester, {
    String score = '85',
  }) => {
    'kcmc': course,
    'cj': score,
    'bfzcj': score,
    'jd': '3.8',
    'xf': '2.0',
    'xnmmc': year,
    'xqmmc': semester,
  };

  testWidgets(
    'defaults to the latest available term and lists only its courses',
    (tester) async {
      await pumpGradesPage(
        tester,
        items: [
          grade('高等数学A', '2025-2026', '第二学期'),
          grade('线性代数', '2025-2026', '第二学期'),
          grade('大学英语', '2025-2026', '第一学期'),
          grade('程序设计', '2024-2025', '第二学期'),
        ],
      );

      final dropdown = tester.widget<AppDropdown<String>>(
        find.byType(AppDropdown<String>),
      );
      // 默认选中最新学期（2025-2026 第二学期）
      expect(dropdown.value, '2025-2026|第二学期');
      expect(find.text('高等数学A'), findsOneWidget);
      expect(find.text('线性代数'), findsOneWidget);
      // 其他学期课程不在当前学期列表中。
      expect(find.text('大学英语'), findsNothing);
      expect(find.text('程序设计'), findsNothing);
    },
  );

  testWidgets('falls back to latest available term when current is absent', (
    tester,
  ) async {
    await pumpGradesPage(
      tester,
      items: [
        grade('程序设计', '2024-2025', '第二学期'),
        grade('思政课', '2024-2025', '第一学期'),
      ],
    );

    final dropdown = tester.widget<AppDropdown<String>>(
      find.byType(AppDropdown<String>),
    );
    // 最新可用学期为 2024-2025 第二学期
    expect(dropdown.value, '2024-2025|第二学期');
    expect(find.text('程序设计'), findsOneWidget);
    expect(find.text('思政课'), findsNothing);
  });

  testWidgets('distribution card and stats reflect only the selected term', (
    tester,
  ) async {
    await pumpGradesPage(
      tester,
      items: [
        grade('高等数学A', '2025-2026', '第二学期', score: '95'),
        grade('大学英语', '2024-2025', '第二学期', score: '40'),
      ],
    );

    // 高等数学A(优)在最新学期，大学英语(不及格)在另一学期。
    expect(find.text('高等数学A'), findsOneWidget);
    expect(find.text('大学英语'), findsNothing);
    // 分布卡：当前学期只有 1 门优，"1" 文本应出现。
    expect(find.text('1'), findsWidgets);
  });

  testWidgets('search filters within the selected term only', (tester) async {
    await pumpGradesPage(
      tester,
      items: [
        grade('高等数学A', '2025-2026', '第二学期'),
        grade('线性代数', '2025-2026', '第二学期'),
        grade('大学英语', '2025-2026', '第一学期'),
      ],
    );

    await tester.enterText(find.byType(TextField), '高等');
    await tester.pump();

    expect(find.text('高等数学A'), findsOneWidget);
    // 第一学期的大学英语不在搜索结果中（搜索仅作用于当前学期）。
    expect(find.text('线性代数'), findsNothing);
    expect(find.text('大学英语'), findsNothing);
  });

  testWidgets('includes an "all terms" option in the dropdown items', (
    tester,
  ) async {
    await pumpGradesPage(
      tester,
      items: [
        grade('高等数学A', '2025-2026', '第二学期'),
        grade('大学英语', '2024-2025', '第二学期'),
      ],
    );

    final dropdown = tester.widget<AppDropdown<String>>(
      find.byType(AppDropdown<String>),
    );
    // 下拉选项应包含「全部学期」作为第一项
    final allItem = dropdown.items
        .where((item) => item.value == GradesTermResolver.allTermKey)
        .firstOrNull;
    expect(allItem, isNotNull);
    expect(allItem!.label, '全部学期');
  });

  Future<void> pumpLoginView(
    WidgetTester tester, {
    required bool automaticLoginPaused,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildGradesLoginView(
            automaticLoginPaused: automaticLoginPaused,
            onAction: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('paused automatic login shows manual-login guidance', (
    tester,
  ) async {
    await pumpLoginView(tester, automaticLoginPaused: true);

    expect(find.text('需要手动登录'), findsOneWidget);
    expect(find.textContaining('自动登录已暂停'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('登录后查看成绩'), findsNothing);
  });

  testWidgets('not paused keeps the original login guidance', (tester) async {
    await pumpLoginView(tester, automaticLoginPaused: false);

    expect(find.text('登录后查看成绩'), findsOneWidget);
    expect(find.textContaining('成绩查询依赖教务系统会话'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('需要手动登录'), findsNothing);
  });

  // ── 身份隔离：账号切换 / 迟到结果 / 登出 ──────────────────────────────────

  Future<void> pumpGradesPageWithFetcher(
    WidgetTester tester,
    GradesFetcher fetcher,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GradesPage(fetchGrades: fetcher)),
      ),
    );
  }

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    String? reason,
  }) async {
    for (
      var elapsed = Duration.zero;
      elapsed < const Duration(seconds: 5) && finder.evaluate().isEmpty;
      elapsed += const Duration(milliseconds: 50)
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(finder, findsWidgets, reason: reason);
  }

  testWidgets('switching account clears the previous owner grades', (
    tester,
  ) async {
    Future<List<GradeEntry>> fetcher(
      String studentId, {
      bool forceRefresh = false,
    }) async {
      if (studentId == '20250002') {
        return [
          GradeEntry.fromJson(grade('B的课程', '2026-2027', '第一学期')),
          GradeEntry.fromJson(grade('B的旧课', '2025-2026', '第二学期')),
        ];
      }
      return [GradeEntry.fromJson(grade('A的课程', '2025-2026', '第二学期'))];
    }

    await pumpGradesPageWithFetcher(tester, fetcher);
    await pumpUntilFound(tester, find.text('A的课程'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.enterText(find.byType(TextField), 'A的课程');
    await tester.pump();
    expect(find.widgetWithText(GradesGradeCard, 'A的课程'), findsOneWidget);

    // debugSetSession 只改状态不通知；markLoggedIn 才让页面收到身份变化通知。
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250002');
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();
    await pumpUntilFound(
      tester,
      find.text('B的课程'),
      reason: '账号切换后应拉取并展示新账号的成绩',
    );
    await tester.pump(const Duration(milliseconds: 500));

    // 新账号数据可见；旧账号课程、搜索词与学期选择都不得残留。
    expect(find.text('B的课程'), findsOneWidget);
    expect(find.text('A的课程'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    final dropdown = tester.widget<AppDropdown<String>>(
      find.byType(AppDropdown<String>),
    );
    // B 账号按自己的最新学期重新默认选择，不沿用 A 的学期 key。
    expect(dropdown.value, '2026-2027|第一学期');
  });

  testWidgets('late result from the previous owner is discarded', (
    tester,
  ) async {
    final aCompleter = Completer<List<GradeEntry>>();

    Future<List<GradeEntry>> fetcher(
      String studentId, {
      bool forceRefresh = false,
    }) {
      if (studentId == '20250002') {
        return Future.value([
          GradeEntry.fromJson(grade('B的课程', '2025-2026', '第二学期')),
        ]);
      }
      return aCompleter.future;
    }

    await pumpGradesPageWithFetcher(tester, fetcher);
    await tester.pump();
    expect(find.text('正在获取成绩…'), findsOneWidget);

    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250002');
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();
    await pumpUntilFound(tester, find.text('B的课程'));
    await tester.pump(const Duration(milliseconds: 500));

    // A 账号的请求此时才迟到完成，不得覆盖 B 账号的页面。
    aCompleter.complete([
      GradeEntry.fromJson(grade('A的课程', '2025-2026', '第二学期')),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('B的课程'), findsOneWidget);
    expect(find.text('A的课程'), findsNothing);
    expect(find.text('正在获取成绩…'), findsNothing);
  });

  testWidgets(
    'failed fetch for the new owner shows an error without old grades',
    (tester) async {
      Future<List<GradeEntry>> fetcher(
        String studentId, {
        bool forceRefresh = false,
      }) async {
        if (studentId == '20250002') {
          throw Exception('B 查询失败');
        }
        return [GradeEntry.fromJson(grade('A的课程', '2025-2026', '第二学期'))];
      }

      await pumpGradesPageWithFetcher(tester, fetcher);
      await pumpUntilFound(tester, find.text('A的课程'));
      await tester.pump(const Duration(milliseconds: 500));

      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250002',
      );
      await ZhengfangAuth.instance.markLoggedIn();
      await tester.pump();
      await pumpUntilFound(
        tester,
        find.byType(AppErrorView),
        reason: 'B 账号首次拉取失败且无同账号数据时应显示错误态',
      );

      // 不能因为旧账号有数据就只弹 toast 并继续展示 A 的成绩。
      expect(find.text('A的课程'), findsNothing);
      expect(find.textContaining('获取成绩失败'), findsOneWidget);

      // 推进 SnackBar 计时器，避免测试结束时留下 pending timer。
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('A的课程'), findsNothing);
    },
  );

  testWidgets('same-account re-login invalidates the prior in-flight fetch', (
    tester,
  ) async {
    final firstCompleter = Completer<List<GradeEntry>>();
    var callCount = 0;

    Future<List<GradeEntry>> fetcher(
      String studentId, {
      bool forceRefresh = false,
    }) {
      callCount++;
      if (callCount == 1) return firstCompleter.future;
      return Future.value([
        GradeEntry.fromJson(grade('A的新课程', '2025-2026', '第二学期')),
      ]);
    }

    await pumpGradesPageWithFetcher(tester, fetcher);
    await tester.pump();
    expect(find.text('正在获取成绩…'), findsOneWidget);

    // 同账号重登：active/studentId 不变，仅身份修订推进。
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '20250001',
      forceRevision: true,
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();
    await pumpUntilFound(
      tester,
      find.text('A的新课程'),
      reason: '同账号重登应作废旧在途请求并重新拉取',
    );
    await tester.pump(const Duration(milliseconds: 500));

    // 重登前的旧请求迟到完成，不得覆盖新会话结果。
    firstCompleter.complete([
      GradeEntry.fromJson(grade('A的旧课程', '2025-2026', '第二学期')),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('A的新课程'), findsOneWidget);
    expect(find.text('A的旧课程'), findsNothing);
  });

  testWidgets('logout clears the previous owner grades', (tester) async {
    Future<List<GradeEntry>> fetcher(
      String studentId, {
      bool forceRefresh = false,
    }) async {
      if (studentId == '20250002') {
        return [GradeEntry.fromJson(grade('B的课程', '2025-2026', '第二学期'))];
      }
      return [GradeEntry.fromJson(grade('A的课程', '2025-2026', '第二学期'))];
    }

    await pumpGradesPageWithFetcher(tester, fetcher);
    await pumpUntilFound(tester, find.text('A的课程'));
    await tester.pump(const Duration(milliseconds: 500));

    await ZhengfangAuth.instance.markLoggedOut();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('A的课程'), findsNothing);
    expect(find.text('登录后查看成绩'), findsOneWidget);

    // 登出后换人登录：旧账号成绩不得复活。
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250002');
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();
    await pumpUntilFound(tester, find.text('B的课程'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('B的课程'), findsOneWidget);
    expect(find.text('A的课程'), findsNothing);

    // 登出按既有行为会拉起教务登录弹窗；推进动画与其内部异步，
    // 避免测试结束时留下未完成的帧调度。
    await tester.pump(const Duration(seconds: 5));
  });
}
