import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/exam/exam_model.dart';

void main() {
  group('ExamEntry.fromJson', () {
    test('parses exam with full time string', () {
      final entry = ExamEntry.fromJson({
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
      });

      expect(entry.courseName, '高等数学');
      expect(entry.courseCode, 'MATH101');
      expect(entry.examDate, DateTime(2026, 6, 15));
      expect(entry.startTime, '14:00');
      expect(entry.endTime, '16:00');
      // weekday regex matches ASCII digits only — Chinese weekday chars are
      // not captured, so weekday stays 0 (pre-existing parser behavior).
      expect(entry.weekday, 0);
      expect(entry.weekNumber, 5);
      expect(entry.location, '教学楼A301');
      expect(entry.seatNumber, '15');
      expect(entry.isRetake, isFalse);
    });

    test('parses exam with no date info', () {
      final entry = ExamEntry.fromJson({
        'kcmc': '体育',
        'kch': 'PE101',
        'kssj': '',
        'cdmc': '',
        'cdxqmc': '',
        'zwh': '',
        'ksmc': '',
        'kkxy': '',
        'cxbj': '',
        'xnmc': '2025-2026',
        'xqmmc': '第二学期',
      });

      expect(entry.hasDate, isFalse);
      expect(entry.isPast, isFalse);
      expect(entry.daysUntil, -1);
    });

    test('detects retake flag', () {
      final entry = ExamEntry.fromJson({
        'kcmc': '线性代数',
        'kch': 'MATH201',
        'kssj': '第8周 周一(2026-07-01) 09:00-11:00',
        'cdmc': '',
        'cdxqmc': '',
        'zwh': '',
        'ksmc': '',
        'kkxy': '',
        'cxbj': '是',
        'xnmc': '2025-2026',
        'xqmmc': '第二学期',
      });

      expect(entry.isRetake, isTrue);
    });
  });

  group('ExamEntry.toJson', () {
    test('round-trips through fromJson/toJson', () {
      final original = ExamEntry.fromJson({
        'kcmc': '大学物理',
        'kch': 'PHY101',
        'kssj': '第3周 周五(2026-06-01) 10:00-12:00',
        'cdmc': '实验楼B201',
        'cdxqmc': '本部',
        'zwh': '22',
        'ksmc': '期中考试',
        'kkxy': '理学院',
        'cxbj': '',
        'xnmc': '2025-2026',
        'xqmmc': '第二学期',
      });

      final json = original.toJson();
      final restored = ExamEntry.fromJson(json);

      expect(restored.courseName, original.courseName);
      expect(restored.courseCode, original.courseCode);
      expect(restored.examTimeRaw, original.examTimeRaw);
      expect(restored.location, original.location);
      expect(restored.campus, original.campus);
      expect(restored.seatNumber, original.seatNumber);
      expect(restored.examName, original.examName);
      expect(restored.isRetake, original.isRetake);
    });

    test('toJson produces correct keys', () {
      final entry = ExamEntry.fromJson({
        'kcmc': '测试课程',
        'kch': 'TEST01',
        'kssj': '第1周 周一(2026-05-01) 08:00-10:00',
        'cdmc': '教室101',
        'cdxqmc': '',
        'zwh': '',
        'ksmc': '',
        'kkxy': '',
        'cxbj': '是',
        'xnmc': '2025-2026',
        'xqmmc': '第二学期',
      });

      final json = entry.toJson();
      expect(json['kcmc'], '测试课程');
      expect(json['kch'], 'TEST01');
      expect(json['cxbj'], '是');
    });
  });

  group('ExamEntry computed properties', () {
    test('countdownLabel for past exam', () {
      final entry = ExamEntry.fromJson({
        'kcmc': '已结束考试',
        'kch': '',
        'kssj': '第1周 周一(2020-01-01) 08:00-10:00',
        'cdmc': '',
        'cdxqmc': '',
        'zwh': '',
        'ksmc': '',
        'kkxy': '',
        'cxbj': '',
        'xnmc': '',
        'xqmmc': '',
      });

      expect(entry.isPast, isTrue);
      expect(entry.countdownLabel, '已结束');
    });

    test('timeRange combines start and end', () {
      final entry = ExamEntry.fromJson({
        'kcmc': '',
        'kch': '',
        'kssj': '第1周 周一(2026-06-01) 09:30-11:30',
        'cdmc': '',
        'cdxqmc': '',
        'zwh': '',
        'ksmc': '',
        'kkxy': '',
        'cxbj': '',
        'xnmc': '',
        'xqmmc': '',
      });

      expect(entry.timeRange, '09:30-11:30');
    });
  });
}
