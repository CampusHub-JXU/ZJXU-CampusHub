import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String dateText(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  final firstExamDate = dateText(DateTime.now().add(const Duration(days: 14)));
  final secondExamDate = dateText(DateTime.now().add(const Duration(days: 30)));

  final sampleItems = [
    {
      'kcmc': '高等数学',
      'kch': 'MATH101',
      'kssj': '第5周 周三($firstExamDate) 14:00-16:00',
      'cdmc': '教学楼A301',
      'cdxqmc': '本部',
      'zwh': '15',
      'ksmc': '期末考试',
      'kkxy': '理学院',
      'cxbj': '',
      'xnmc': '2025-2026',
      'xqmmc': '第二学期',
    },
    {
      'kcmc': '大学物理',
      'kch': 'PHY101',
      'kssj': '第8周 周一($secondExamDate) 09:00-11:00',
      'cdmc': '实验楼B201',
      'cdxqmc': '本部',
      'zwh': '',
      'ksmc': '',
      'kkxy': '',
      'cxbj': '',
      'xnmc': '2025-2026',
      'xqmmc': '第二学期',
    },
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    ExamService.instance.debugReset();
  });

  group('ExamService.restoreCache', () {
    test('restores exams from preferences', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('exam_cached_data', jsonEncode(sampleItems));
      final restored = await ExamService.instance.restoreCache();

      expect(restored, isTrue);
      expect(ExamService.instance.cachedExams, isNotNull);
      expect(ExamService.instance.cachedExams, hasLength(2));
      expect(ExamService.instance.cachedExams!.first.courseName, '高等数学');
    });

    test('returns false when no cache exists', () async {
      final restored = await ExamService.instance.restoreCache();
      expect(restored, isFalse);
      expect(ExamService.instance.cachedExams, isNull);
    });

    test('sorts exams by date during restore', () async {
      final prefs = await SharedPreferences.getInstance();
      // Reverse chronological order in stored data.
      await prefs.setString(
        'exam_cached_data',
        jsonEncode([
          sampleItems[1], // July
          sampleItems[0], // June
        ]),
      );
      await ExamService.instance.restoreCache();

      expect(ExamService.instance.cachedExams!.first.courseName, '高等数学');
    });
  });

  group('ExamService accessors', () {
    test('nextExam returns first upcoming exam', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('exam_cached_data', jsonEncode(sampleItems));
      await ExamService.instance.restoreCache();

      final next = ExamService.instance.nextExam;
      expect(next, isNotNull);
      expect(next!.courseName, '高等数学');
    });

    test('nextExam returns null when no cache', () {
      expect(ExamService.instance.nextExam, isNull);
    });
  });
}
