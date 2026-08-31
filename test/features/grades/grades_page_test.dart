import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/grades/grades_page.dart';
import 'package:jxu_campus_hub/features/grades/grades_term_resolver.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250001');
  });

  Future<void> pumpGradesPage(
    WidgetTester tester, {
    required List<Map<String, dynamic>> items,
  }) async {
    final adapter = MockHttpClientAdapter();
    adapter.register('POST', '/jwglxt/cjcx/cjcx_cxDgXscj.html', (
      options,
    ) async {
      return ResponseBody.fromString(
        jsonEncode({'items': items}),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GradesPage())));
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
}
