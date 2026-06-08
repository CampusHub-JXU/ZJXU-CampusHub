import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/exam/exam_page.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  testWidgets('shows cached exams while logged out', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'exam_cached_data',
      jsonEncode([
        {
          'kcmc': '高等数学',
          'kch': 'MATH101',
          'kssj': '第8周 周三(2026-07-01) 14:00-16:00',
          'cdmc': '教学楼A301',
          'cdxqmc': '本部',
          'zwh': '15',
          'ksmc': '期末考试',
          'kkxy': '理学院',
          'cxbj': '',
          'xnmc': '2025-2026',
          'xqmmc': '第二学期',
        },
      ]),
    );
    await prefs.setInt(
      'exam_cached_at',
      DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch,
    );
    await ExamService.instance.restoreCache();

    await tester.pumpWidget(const MaterialApp(home: ExamPage()));
    await tester.pump();

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('登录后查看考试安排'), findsNothing);
  });
}
