import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sampleItems = [
    {
      'kcmc': '高等数学',
      'kch': 'MATH101',
      'kssj': '第5周 周三(2026-06-15) 14:00-16:00',
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
      'kssj': '第8周 周一(2026-07-01) 09:00-11:00',
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
      await prefs.setInt(
        'exam_cached_at',
        DateTime.now().millisecondsSinceEpoch,
      );

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
      await prefs.setInt(
        'exam_cached_at',
        DateTime.now().millisecondsSinceEpoch,
      );

      await ExamService.instance.restoreCache();

      expect(ExamService.instance.cachedExams!.first.courseName, '高等数学');
    });
  });

  group('ExamService.isCacheFresh', () {
    test('returns false when no cache time is recorded', () {
      expect(ExamService.instance.isCacheFresh, isFalse);
    });

    test('returns true when cache is within refresh window', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('exam_cached_data', jsonEncode(sampleItems));
      await prefs.setInt(
        'exam_cached_at',
        DateTime.now().millisecondsSinceEpoch,
      );

      await ExamService.instance.restoreCache();

      expect(ExamService.instance.isCacheFresh, isTrue);
    });

    test('returns false when cache is older than refresh window', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('exam_cached_data', jsonEncode(sampleItems));
      // 12 hours ago — beyond 6-hour window.
      await prefs.setInt(
        'exam_cached_at',
        DateTime.now()
            .subtract(const Duration(hours: 12))
            .millisecondsSinceEpoch,
      );

      await ExamService.instance.restoreCache();

      expect(ExamService.instance.isCacheFresh, isFalse);
    });
  });

  group('ExamService accessors', () {
    test('nextExam returns first upcoming exam', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('exam_cached_data', jsonEncode(sampleItems));
      await prefs.setInt(
        'exam_cached_at',
        DateTime.now().millisecondsSinceEpoch,
      );

      await ExamService.instance.restoreCache();

      final next = ExamService.instance.nextExam;
      expect(next, isNotNull);
      expect(next!.courseName, '高等数学');
    });

    test('upcomingExams returns non-past exams with dates', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('exam_cached_data', jsonEncode(sampleItems));
      await prefs.setInt(
        'exam_cached_at',
        DateTime.now().millisecondsSinceEpoch,
      );

      await ExamService.instance.restoreCache();

      expect(ExamService.instance.upcomingExams, hasLength(2));
    });

    test('nextExam returns null when no cache', () {
      expect(ExamService.instance.nextExam, isNull);
    });

    test('upcomingExams returns empty when no cache', () {
      expect(ExamService.instance.upcomingExams, isEmpty);
    });
  });
}
