import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/academic/exam_model.dart';
import 'package:jxu_campus_hub/features/home/models/home_today_agenda.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';

ExamEntry _makeExam({
  required String courseName,
  required DateTime? examDate,
  String startTime = '09:00',
  String endTime = '11:00',
  String campus = '梁林校区',
  String location = '1号楼201',
}) {
  return ExamEntry(
    courseName: courseName,
    courseCode: 'CS101',
    examTimeRaw: '',
    examDate: examDate,
    startTime: startTime,
    endTime: endTime,
    location: location,
    campus: campus,
    seatNumber: '12',
    examName: '期末考试',
    department: '信息学院',
    isRetake: false,
    academicYear: '2026-2027',
    semester: '1',
    weekday: examDate?.weekday ?? 1,
    weekNumber: 12,
  );
}

SecondClassroomActivity _makeActivity({
  required int id,
  required String title,
  required DateTime? startAt,
  DateTime? endAt,
  String location = '报告厅',
  bool isRegistered = false,
}) {
  return SecondClassroomActivity(
    id: id,
    title: title,
    coverId: '',
    iconId: '',
    registrationStartAt: null,
    registrationEndAt: null,
    activityStartAt: startAt,
    activityEndAt: endAt,
    creditHours: 1.0,
    location: location,
    summary: '',
    contactName: '',
    contactPhone: '',
    categoryName: '',
    organizerName: '',
    capacity: 100,
    enrolledCount: 20,
    isRegistered: isRegistered,
    hasCheckedIn: false,
    hasRetaken: false,
  );
}

void main() {
  final now = DateTime(2026, 11, 21, 14, 30);

  group('resolveHomeTodayAgenda', () {
    test('returns empty agenda when all sources are empty', () {
      final agenda = resolveHomeTodayAgenda(
        now: now,
        exams: const [],
        subscribedActivities: const [],
        cachedActivities: const [],
      );

      expect(agenda.hasExtras, isFalse);
      expect(agenda.upcomingExams, isEmpty);
      expect(agenda.upcomingActivities, isEmpty);
    });

    test('filters exams to 1..7 days ahead, excludes today/past/>7d, sorts and caps at 3', () {
      final agenda = resolveHomeTodayAgenda(
        now: now,
        exams: [
          _makeExam(courseName: '昨天考完', examDate: DateTime(2026, 11, 20)),
          _makeExam(courseName: '今天考试', examDate: DateTime(2026, 11, 21)),
          _makeExam(courseName: '8天后考试', examDate: DateTime(2026, 11, 29)),
          _makeExam(courseName: '第7天考试', examDate: DateTime(2026, 11, 28)),
          _makeExam(courseName: '明天考试', examDate: DateTime(2026, 11, 22)),
          _makeExam(courseName: '3天后考试', examDate: DateTime(2026, 11, 24)),
          _makeExam(courseName: '2天后考试', examDate: DateTime(2026, 11, 23)),
        ],
        subscribedActivities: const [],
        cachedActivities: const [],
      );

      expect(agenda.hasExtras, isTrue);
      expect(agenda.upcomingExams.map((e) => e.courseName).toList(), [
        '明天考试',
        '2天后考试',
        '3天后考试',
      ]);
      expect(agenda.upcomingExams[0].dateLabel, '明天');
      expect(agenda.upcomingExams[0].isUrgent, isTrue);
      expect(agenda.upcomingExams[1].dateLabel, '2天后');
      expect(agenda.upcomingExams[1].isUrgent, isTrue);
      expect(agenda.upcomingExams[2].dateLabel, '3天后');
      expect(agenda.upcomingExams[2].isUrgent, isFalse);
    });

    test('excludes exam already shown in Hero to avoid duplication', () {
      final agenda = resolveHomeTodayAgenda(
        now: now,
        exams: [
          _makeExam(courseName: '微观经济学', examDate: DateTime(2026, 11, 22)),
          _makeExam(courseName: '数据结构', examDate: DateTime(2026, 11, 24)),
        ],
        subscribedActivities: const [],
        cachedActivities: const [],
        excludeExamCourseName: '微观经济学',
      );

      expect(agenda.upcomingExams.map((e) => e.courseName).toList(), ['数据结构']);
    });

    test('merges registered and subscribed activities, deduplicates with registered priority, detects ongoing', () {
      final agenda = resolveHomeTodayAgenda(
        now: now,
        exams: const [],
        subscribedActivities: [
          _makeActivity(
            id: 10,
            title: '重复活动（订阅版）',
            startAt: DateTime(2026, 11, 22, 19, 0),
            endAt: DateTime(2026, 11, 22, 21, 0),
          ),
          _makeActivity(
            id: 11,
            title: '正在进行的讲座',
            startAt: DateTime(2026, 11, 21, 14, 0),
            endAt: DateTime(2026, 11, 21, 16, 0),
          ),
          _makeActivity(
            id: 12,
            title: '已结束的活动',
            startAt: DateTime(2026, 11, 21, 9, 0),
            endAt: DateTime(2026, 11, 21, 11, 0),
          ),
          _makeActivity(
            id: 13,
            title: '10天后活动',
            startAt: DateTime(2026, 12, 1, 14, 0),
            endAt: DateTime(2026, 12, 1, 16, 0),
          ),
        ],
        cachedActivities: [
          _makeActivity(
            id: 10,
            title: '重复活动（已报名版）',
            startAt: DateTime(2026, 11, 22, 19, 0),
            endAt: DateTime(2026, 11, 22, 21, 0),
            isRegistered: true,
          ),
          _makeActivity(
            id: 14,
            title: '未报名的普通缓存活动',
            startAt: DateTime(2026, 11, 21, 18, 0),
            endAt: DateTime(2026, 11, 21, 20, 0),
            isRegistered: false,
          ),
        ],
      );

      expect(agenda.upcomingActivities.length, 2);
      expect(agenda.upcomingActivities[0].title, '正在进行的讲座');
      expect(agenda.upcomingActivities[0].isOngoing, isTrue);
      expect(agenda.upcomingActivities[0].timeLabel, '进行中');
      expect(agenda.upcomingActivities[0].badgeLabel, '已订阅');

      expect(agenda.upcomingActivities[1].id, 10);
      expect(agenda.upcomingActivities[1].badgeLabel, '已报名');
      expect(agenda.upcomingActivities[1].timeLabel, '明天 19:00');
    });
  });
}
