import 'package:flutter_test/flutter_test.dart';
import 'package:jiaxing_university_portal/features/schedule/schedule_model.dart';
import 'package:jiaxing_university_portal/features/schedule/schedule_service.dart';

void main() {
  group('ScheduleService.parseCourseChangeMessages', () {
    test('parses reschedule, makeup and cancellation messages', () {
      final rules = ScheduleService.instance.parseCourseChangeMessages([
        '调课提醒:胡亚楠老师于第5周星期四第8-9节在铭德楼467上的AI+创新创业基础课程调课到由胡亚楠老师在第5周星期五第8-9节在铭德楼468上的AI+创新创业基础课程，请各位同学相互告知！',
        '补课提醒:杨月红老师将在第17周星期六第11-12节对课程健身1进行补课，请各位同学相互告知！',
        '停课提醒:原定汤龙老师在第3周星期一第11-13节于尚德楼142上的政治经济学课程停课，请各位同学相互告知！',
      ]);

      expect(rules, hasLength(3));

      final rescheduleRule = rules.firstWhere(
        (rule) => rule.type == CourseChangeType.reschedule,
      );
      expect(rescheduleRule.courseName, 'AI+创新创业基础');
      expect(rescheduleRule.originalLesson?.week, 5);
      expect(rescheduleRule.originalLesson?.weekday, 4);
      expect(rescheduleRule.targetLesson?.weekday, 5);
      expect(rescheduleRule.classroom, '铭德楼468');

      final makeupRule = rules.firstWhere(
        (rule) => rule.type == CourseChangeType.makeup,
      );
      expect(makeupRule.courseName, '健身1');
      expect(makeupRule.targetLesson?.week, 17);
      expect(makeupRule.targetLesson?.weekday, 6);

      final cancelRule = rules.firstWhere(
        (rule) => rule.type == CourseChangeType.cancel,
      );
      expect(cancelRule.courseName, '政治经济学');
      expect(cancelRule.originalLesson?.week, 3);
      expect(cancelRule.originalLesson?.startLesson, 11);
      expect(cancelRule.originalLesson?.endLesson, 13);
    });
  });

  group('ScheduleService.buildEffectiveWeekCourses', () {
    test('replaces original class with adjusted class in the same week', () {
      const baseCourses = [
        CourseEntry(
          courseName: 'AI+创新创业基础',
          teacherName: '胡亚楠',
          weekday: 4,
          startLesson: 8,
          endLesson: 9,
          weekRange: '1-18周',
          classroom: '铭德楼467',
          campus: '梁林校区',
          typeSymbol: '',
        ),
      ];

      final rules = ScheduleService.instance.parseCourseChangeMessages([
        '调课提醒:胡亚楠老师于第5周星期四第8-9节在铭德楼467上的AI+创新创业基础课程调课到由胡亚楠老师在第5周星期五第8-9节在铭德楼468上的AI+创新创业基础课程，请各位同学相互告知！',
      ]);

      final weekCourses = ScheduleService.instance.buildEffectiveWeekCourses(
        courses: baseCourses,
        week: 5,
        changeRules: rules,
      );

      expect(weekCourses.where((course) => course.weekday == 4), isEmpty);
      expect(weekCourses.where((course) => course.weekday == 5), hasLength(1));
      expect(weekCourses.single.classroom, '铭德楼468');
    });

    test('adds makeup class for target week only', () {
      const baseCourses = [
        CourseEntry(
          courseName: '健身1',
          teacherName: '杨月红',
          weekday: 3,
          startLesson: 6,
          endLesson: 7,
          weekRange: '1-16周',
          classroom: '嘉兴体育馆健身房',
          campus: '嘉兴校区',
          typeSymbol: '',
        ),
      ];

      final rules = ScheduleService.instance.parseCourseChangeMessages([
        '补课提醒:杨月红老师将在第17周星期六第11-12节对课程健身1进行补课，请各位同学相互告知！',
      ]);

      final week17Courses = ScheduleService.instance.buildEffectiveWeekCourses(
        courses: baseCourses,
        week: 17,
        changeRules: rules,
      );
      final week16Courses = ScheduleService.instance.buildEffectiveWeekCourses(
        courses: baseCourses,
        week: 16,
        changeRules: rules,
      );

      expect(
        week17Courses.where((course) => course.weekday == 6),
        hasLength(1),
      );
      expect(
        week17Courses.any((course) => course.classroom == '嘉兴体育馆健身房'),
        isTrue,
      );
      expect(week16Courses.where((course) => course.weekday == 6), isEmpty);
    });
  });
}
