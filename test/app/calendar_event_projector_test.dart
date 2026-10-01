import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/calendar_event_projector.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_change_rule.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';

void main() {
  // 固定时间基准（第一学期：2026-2027 学年第 1 学期）。
  const term = ScheduleTermContext(academicYear: 2026, term: 3);
  final now = DateTime(2026, 9, 10, 12);
  final mondayStart = DateTime(2026, 8, 31); // 周一
  final tuesdayStart = DateTime(2026, 9, 1); // 周二
  final wednesdayStart = DateTime(2026, 9, 2); // 周三

  const owner = '20230001';

  /// Asia/Shanghai 墙钟 → UTC 毫秒（测试侧独立算法，固定 +8，不读设备时区）。
  int shanghaiMillis(int year, int month, int day, int hour, int minute) {
    final wall = DateTime.utc(year, month, day, hour, minute);
    return wall.millisecondsSinceEpoch -
        const Duration(hours: 8).inMilliseconds;
  }

  const mathCourse = CourseEntry(
    courseName: '高等数学',
    teacherName: '张老师',
    weekday: 1,
    startLesson: 1,
    endLesson: 2,
    weekRange: '1-4周',
    classroom: 'A101',
    campus: '梁林校区',
    typeSymbol: '◆',
  );

  ScheduleCacheSnapshot snapshotWith({
    List<CourseEntry>? courses,
    List<CourseChangeRule>? changeRules,
    DateTime? scheduleUpdatedAt,
    DateTime? changeRulesUpdatedAt,
    bool clearScheduleUpdatedAt = false,
    bool clearChangeRulesUpdatedAt = false,
    String studentId = owner,
    ScheduleTermContext termContext = term,
    bool changeRulesCurrentScoped = true,
    bool changeRulesDateAware = true,
  }) {
    return ScheduleCacheSnapshot(
      studentId: studentId,
      termContext: termContext,
      courses: courses ?? const [mathCourse],
      changeRules: changeRules ?? const [],
      scheduleUpdatedAt: clearScheduleUpdatedAt
          ? null
          : scheduleUpdatedAt ?? now.subtract(const Duration(hours: 2)),
      changeRulesUpdatedAt: clearChangeRulesUpdatedAt
          ? null
          : changeRulesUpdatedAt ?? now.subtract(const Duration(hours: 2)),
      changeRulesCurrentScoped: changeRulesCurrentScoped,
      changeRulesDateAware: changeRulesDateAware,
    );
  }

  List<ProjectedCourseOccurrence> project(
    ScheduleCacheSnapshot snapshot, {
    String verifiedOwner = owner,
    ScheduleTermContext confirmedCurrentTerm = term,
    DateTime? semesterStartDate,
    DateTime? at,
  }) {
    return projectCurrentTermCalendarEvents(
      snapshot: snapshot,
      verifiedOwner: verifiedOwner,
      confirmedCurrentTerm: confirmedCurrentTerm,
      semesterStartDate: semesterStartDate ?? mondayStart,
      now: at ?? now,
    );
  }

  void expectFailure(
    CalendarProjectionFailure reason,
    ScheduleCacheSnapshot snapshot, {
    String verifiedOwner = owner,
    ScheduleTermContext confirmedCurrentTerm = term,
    DateTime? semesterStartDate,
    DateTime? at,
  }) {
    expect(
      () => project(
        snapshot,
        verifiedOwner: verifiedOwner,
        confirmedCurrentTerm: confirmedCurrentTerm,
        semesterStartDate: semesterStartDate,
        at: at,
      ),
      throwsA(
        isA<CalendarProjectionException>().having(
          (error) => error.reason,
          'reason',
          reason,
        ),
      ),
    );
  }

  group('展开与日期校准', () {
    test('周一开学日：第 1 周周一课程按当天展开，不因开学日过滤丢失', () {
      final occurrences = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-2周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '◆',
            ),
          ],
        ),
      );

      expect(occurrences, hasLength(2));
      expect(occurrences[0].week, 1);
      expect(occurrences[0].startMillis, shanghaiMillis(2026, 8, 31, 8, 0));
      expect(occurrences[0].endMillis, shanghaiMillis(2026, 8, 31, 9, 25));
      expect(occurrences[1].week, 2);
      expect(occurrences[1].startMillis, shanghaiMillis(2026, 9, 7, 8, 0));
      expect(occurrences[0].startTimeUtc.isUtc, isTrue);
    });

    test('非周一开学日：第 1 周从开学日所在周的周一算起', () {
      final course = const CourseEntry(
        courseName: '大学英语',
        teacherName: '李老师',
        weekday: 1,
        startLesson: 3,
        endLesson: 4,
        weekRange: '1周',
        classroom: 'B203',
        campus: '梁林校区',
        typeSymbol: '',
      );

      for (final start in [tuesdayStart, wednesdayStart]) {
        final occurrences = project(
          snapshotWith(courses: [course]),
          semesterStartDate: start,
        );
        expect(occurrences, hasLength(1), reason: '开学日 $start 不应丢第 1 周课程');
        expect(
          occurrences.single.startMillis,
          shanghaiMillis(2026, 8, 31, 9, 45),
          reason: '开学日 $start 的第 1 周周一应为 8/31',
        );
      }
    });

    test('固定北京时间墙钟：毫秒值与设备本地时区无关', () {
      final occurrences = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '◆',
            ),
            CourseEntry(
              courseName: '程序设计',
              teacherName: '王老师',
              weekday: 1,
              startLesson: 6,
              endLesson: 6,
              weekRange: '1周',
              classroom: '机房302',
              campus: '梁林校区',
              typeSymbol: '●',
            ),
          ],
        ),
      );

      expect(occurrences, hasLength(2));
      // 08:00 北京时间 = 00:00Z；13:30 北京时间 = 05:30Z。
      expect(
        occurrences[0].startMillis,
        DateTime.utc(2026, 8, 31).millisecondsSinceEpoch,
      );
      expect(
        occurrences[1].startMillis,
        DateTime.utc(2026, 8, 31, 5, 30).millisecondsSinceEpoch,
      );
      expect(
        occurrences[1].startMillis,
        DateTime.utc(
          2026,
          8,
          31,
          13,
          30,
        ).subtract(const Duration(hours: 8)).millisecondsSinceEpoch,
      );
    });

    test('周末课程按 weekday 7 校准到当周周日', () {
      final occurrences = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '体育',
              teacherName: '赵老师',
              weekday: 7,
              startLesson: 11,
              endLesson: 13,
              weekRange: '1周',
              classroom: '田径场',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      );

      expect(occurrences, hasLength(1));
      expect(occurrences.single.weekday, 7);
      expect(
        occurrences.single.startMillis,
        shanghaiMillis(2026, 9, 6, 18, 30),
      );
      expect(occurrences.single.endMillis, shanghaiMillis(2026, 9, 6, 20, 40));
    });

    test('20 周上限：超出当前学期教学周的周次不投影', () {
      final occurrences = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '大学物理',
              teacherName: '陈老师',
              weekday: 2,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-25周',
              classroom: 'C101',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      );

      expect(occurrences, hasLength(20));
      expect(
        occurrences.map((item) => item.week),
        List.generate(20, (i) => i + 1),
      );
    });
  });

  group('单双周与多段周', () {
    test('单周修饰与多段周按 isInWeek 展开', () {
      final occurrences = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '线性代数',
              teacherName: '孙老师',
              weekday: 3,
              startLesson: 3,
              endLesson: 4,
              weekRange: '1-5周(单),7-9周',
              classroom: 'D202',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      );

      expect(occurrences.map((item) => item.week), [1, 3, 5, 7, 8, 9]);
      // 第 1 周周三 = 2026-09-02；第 3 周周三 = 2026-09-16。
      expect(occurrences[0].startMillis, shanghaiMillis(2026, 9, 2, 9, 45));
      expect(occurrences[1].startMillis, shanghaiMillis(2026, 9, 16, 9, 45));
      expect(occurrences.map((item) => item.businessKey).toSet(), hasLength(6));
    });
  });

  group('调课 / 停课 / 补课', () {
    test('停课规则移除对应周次', () {
      final occurrences = project(
        snapshotWith(
          changeRules: const [
            CourseChangeRule(
              type: CourseChangeType.cancel,
              originalLesson: CourseLessonSlot(
                week: 2,
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
              ),
              courseName: '高等数学',
              termContext: term,
            ),
          ],
        ),
      );

      expect(occurrences.map((item) => item.week), [1, 3, 4]);
    });

    test('调课规则：原周次移除，目标周次按目标星期/节次/教室展开', () {
      final occurrences = project(
        snapshotWith(
          changeRules: const [
            CourseChangeRule(
              type: CourseChangeType.reschedule,
              originalLesson: CourseLessonSlot(
                week: 2,
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
              ),
              targetLesson: CourseLessonSlot(
                week: 2,
                weekday: 3,
                startLesson: 5,
                endLesson: 6,
              ),
              courseName: '高等数学',
              teacherName: '李老师',
              classroom: 'B202',
              termContext: term,
            ),
          ],
        ),
      );

      expect(occurrences, hasLength(4));
      final moved = occurrences.firstWhere((item) => item.week == 2);
      expect(moved.weekday, 3);
      expect(moved.startLesson, 5);
      expect(moved.endLesson, 6);
      expect(moved.location, 'B202');
      expect(moved.title, '高等数学');
      // 第 2 周周三 = 2026-09-09；第 5 节 11:15 北京时间。
      expect(moved.startMillis, shanghaiMillis(2026, 9, 9, 11, 15));
      // 原周一 1-2 节的周 2 记录已移除。
      expect(
        occurrences.where((item) => item.week == 2 && item.weekday == 1),
        isEmpty,
      );
    });

    test('补课规则新增目标周次课程', () {
      final occurrences = project(
        snapshotWith(
          changeRules: const [
            CourseChangeRule(
              type: CourseChangeType.makeup,
              targetLesson: CourseLessonSlot(
                week: 3,
                weekday: 5,
                startLesson: 9,
                endLesson: 10,
              ),
              courseName: '线性代数',
              classroom: 'C303',
              termContext: term,
            ),
          ],
        ),
      );

      expect(occurrences, hasLength(5));
      final makeup = occurrences.firstWhere(
        (item) => item.week == 3 && item.weekday == 5,
      );
      expect(makeup.title, '线性代数');
      expect(makeup.location, 'C303');
      expect(makeup.startLesson, 9);
      // 第 3 周周五 = 2026-09-18；第 9 节 16:00 北京时间。
      expect(makeup.startMillis, shanghaiMillis(2026, 9, 18, 16, 0));
    });

    test('无学期证明的调课规则与课表展示语义一致地不应用', () {
      final occurrences = project(
        snapshotWith(
          changeRules: const [
            CourseChangeRule(
              type: CourseChangeType.cancel,
              originalLesson: CourseLessonSlot(
                week: 2,
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
              ),
              courseName: '高等数学',
              termContext: term,
            ),
            CourseChangeRule(
              type: CourseChangeType.cancel,
              originalLesson: CourseLessonSlot(
                week: 3,
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
              ),
              courseName: '高等数学',
            ),
            CourseChangeRule(
              type: CourseChangeType.cancel,
              originalLesson: CourseLessonSlot(
                week: 4,
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
              ),
              courseName: '高等数学',
              termContext: ScheduleTermContext(academicYear: 2025, term: 12),
            ),
          ],
        ),
      );

      // 只有明确属于当前学期的周 2 停课生效。
      expect(occurrences.map((item) => item.week), [1, 3, 4]);
    });
  });

  group('fail closed：身份 / 学期 / 开学日', () {
    test('空身份与归属不一致都拒绝', () {
      expectFailure(
        CalendarProjectionFailure.ownerUnverified,
        snapshotWith(),
        verifiedOwner: '   ',
      );
      expectFailure(
        CalendarProjectionFailure.ownerMismatch,
        snapshotWith(),
        verifiedOwner: '20239999',
      );
      expectFailure(
        CalendarProjectionFailure.ownerMismatch,
        snapshotWith(studentId: ''),
      );
    });

    test('上学期回退快照不能投影为当前学期', () {
      expectFailure(
        CalendarProjectionFailure.termMismatch,
        snapshotWith(
          termContext: const ScheduleTermContext(academicYear: 2025, term: 3),
        ),
      );
    });

    test('已确认学期必须等于按 now 推算的当前学期', () {
      expectFailure(
        CalendarProjectionFailure.termNotCurrent,
        snapshotWith(
          termContext: const ScheduleTermContext(academicYear: 2026, term: 12),
        ),
        confirmedCurrentTerm: const ScheduleTermContext(
          academicYear: 2026,
          term: 12,
        ),
        semesterStartDate: DateTime(2026, 3, 2),
      );
    });

    test('开学日与已确认学期错配时拒绝', () {
      expectFailure(
        CalendarProjectionFailure.semesterStartMismatch,
        snapshotWith(),
        semesterStartDate: DateTime(2026, 3, 2),
      );
    });

    test('开学日年份离谱或距当前过远时拒绝', () {
      expectFailure(
        CalendarProjectionFailure.semesterStartUnreasonable,
        snapshotWith(),
        semesterStartDate: DateTime(1999, 9, 1),
      );
      // 距 now（2026-09-10）116 天，超过开学前窗口。
      expectFailure(
        CalendarProjectionFailure.semesterStartUnreasonable,
        snapshotWith(),
        semesterStartDate: DateTime(2027, 1, 4),
      );
      // 第 20 周结束后 35 天，超出学期范围。
      expectFailure(
        CalendarProjectionFailure.semesterStartUnreasonable,
        snapshotWith(
          scheduleUpdatedAt: DateTime(2027, 1, 25, 10),
          changeRulesUpdatedAt: DateTime(2027, 1, 25, 10),
        ),
        semesterStartDate: DateTime(2026, 8, 3),
        at: DateTime(2027, 1, 25, 12),
      );
    });
  });

  group('fail closed：快照时效与调课规则可信度', () {
    test('缺少课表刷新时间或课程为空时拒绝', () {
      expectFailure(
        CalendarProjectionFailure.scheduleMissing,
        snapshotWith(clearScheduleUpdatedAt: true),
      );
      expectFailure(
        CalendarProjectionFailure.scheduleMissing,
        snapshotWith(courses: const []),
      );
    });

    test('课表快照超过 7 天视为过期', () {
      expectFailure(
        CalendarProjectionFailure.scheduleStale,
        snapshotWith(scheduleUpdatedAt: now.subtract(const Duration(days: 8))),
      );
    });

    test('调课规则未按当前学期抓取或缺少日期语义时拒绝', () {
      expectFailure(
        CalendarProjectionFailure.changeRulesUntrusted,
        snapshotWith(changeRulesCurrentScoped: false),
      );
      expectFailure(
        CalendarProjectionFailure.changeRulesUntrusted,
        snapshotWith(changeRulesDateAware: false),
      );
    });

    test('调课规则缺少刷新时间或已过期时拒绝', () {
      expectFailure(
        CalendarProjectionFailure.changeRulesStale,
        snapshotWith(clearChangeRulesUpdatedAt: true),
      );
      expectFailure(
        CalendarProjectionFailure.changeRulesStale,
        snapshotWith(
          changeRulesUpdatedAt: now.subtract(const Duration(days: 2)),
        ),
      );
    });
  });

  group('fail closed：课程结构与时间', () {
    CourseEntry courseWith({
      int weekday = 1,
      int startLesson = 1,
      int endLesson = 2,
      String weekRange = '1-4周',
      String courseName = '高等数学',
    }) => CourseEntry(
      courseName: courseName,
      teacherName: '张老师',
      weekday: weekday,
      startLesson: startLesson,
      endLesson: endLesson,
      weekRange: weekRange,
      classroom: 'A101',
      campus: '梁林校区',
      typeSymbol: '',
    );

    test('星期超出 1–7 拒绝', () {
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(weekday: 8)]),
      );
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(weekday: 0)]),
      );
    });

    test('节次超出 1–13 或顺序颠倒拒绝', () {
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(startLesson: 14, endLesson: 14)]),
      );
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(startLesson: 2, endLesson: 1)]),
      );
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(startLesson: 0, endLesson: 1)]),
      );
    });

    test('周次缺失或与 1–20 周无交集拒绝', () {
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(weekRange: '')]),
      );
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(weekRange: '21-25周')]),
      );
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(weekRange: '待定')]),
      );
    });

    test('标题为空拒绝', () {
      expectFailure(
        CalendarProjectionFailure.invalidCourse,
        snapshotWith(courses: [courseWith(courseName: '   ')]),
      );
    });
  });

  group('重复课程稳定去重', () {
    test('完全重复的课程只投影一次', () {
      final snapshot = snapshotWith(courses: const [mathCourse, mathCourse]);

      expect(project(snapshot), hasLength(4));
    });

    test('不同周次区间但同一周次命中的重复课程只保留一条', () {
      final occurrences = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-3周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '',
            ),
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-5周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      );

      expect(occurrences.map((item) => item.week), [1, 2, 3, 4, 5]);
    });

    test('重复投影与课程顺序变化都得到相同 businessKey 序列', () {
      final snapshot = snapshotWith(
        courses: const [
          mathCourse,
          CourseEntry(
            courseName: '大学英语',
            teacherName: '李老师',
            weekday: 3,
            startLesson: 3,
            endLesson: 4,
            weekRange: '1-2周',
            classroom: 'B203',
            campus: '梁林校区',
            typeSymbol: '',
          ),
        ],
      );
      final reversed = snapshotWith(
        courses: const [
          CourseEntry(
            courseName: '大学英语',
            teacherName: '李老师',
            weekday: 3,
            startLesson: 3,
            endLesson: 4,
            weekRange: '1-2周',
            classroom: 'B203',
            campus: '梁林校区',
            typeSymbol: '',
          ),
          mathCourse,
        ],
      );

      final first = project(snapshot).map((item) => item.businessKey).toList();
      final second = project(snapshot).map((item) => item.businessKey).toList();
      final third = project(reversed).map((item) => item.businessKey).toList();

      expect(first, hasLength(6));
      expect(second, first);
      expect(third, first);
    });
  });

  group('输出字段与私有映射', () {
    test('businessKey 稳定、随周次变化且不携带身份或 URI', () {
      final occurrences = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-2周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      );

      expect(occurrences, hasLength(2));
      expect(occurrences[0].businessKey, isNot(occurrences[1].businessKey));
      for (final occurrence in occurrences) {
        expect(occurrence.businessKey, isNotEmpty);
        expect(occurrence.businessKey, isNot(contains(owner)));
        expect(occurrence.businessKey, isNot(contains('jxucampushub://')));
        expect(
          occurrence.businessKey.length,
          lessThanOrEqualTo(CalendarSyncProtocol.maxBusinessKeyLength),
        );
      }
    });

    test('不同教室/教师/节次的课程得到不同 businessKey', () {
      final base = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      ).single;
      final otherRoom = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1周',
              classroom: 'A102',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      ).single;

      expect(base.businessKey, isNot(otherRoom.businessKey));
    });

    test('toEventDraft / toEventPlan 只使用调用方提供的 opaqueId', () {
      final occurrence = project(
        snapshotWith(
          courses: const [
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1周',
              classroom: 'A101',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
      ).single;

      const opaqueId = '3f1a0c62-7c4a-4c8b-9a2e-6f0d5b7c1e42';
      final draft = occurrence.toEventDraft(opaqueId: opaqueId);

      expect(draft.validate(), isNull);
      expect(draft.opaqueId, opaqueId);
      expect(draft.title, '高等数学');
      expect(draft.location, 'A101');
      expect(draft.startMillis, occurrence.startMillis);
      expect(draft.endMillis, occurrence.endMillis);
      expect(draft.reminderMinutes, 10);
      expect(draft.timeZone, ProjectedCourseOccurrence.timeZoneId);
      expect(draft.timeZone, 'Asia/Shanghai');
      expect(occurrence.reminderMinutes, 10);

      final plan = occurrence.toEventPlan(opaqueId: opaqueId);
      expect(plan.validate(), isNull);
      expect(plan.businessKey, occurrence.businessKey);
      expect(plan.opaqueId, opaqueId);
    });
  });

  group('第二学期（term 12）同样成立', () {
    test('第二学期按开学日周一展开，且历史学期回退快照被拒绝', () {
      const secondTerm = ScheduleTermContext(academicYear: 2025, term: 12);
      final secondTermNow = DateTime(2026, 3, 10, 12);
      final secondTermStart = DateTime(2026, 3, 2); // 周一

      final occurrences = project(
        snapshotWith(
          termContext: secondTerm,
          scheduleUpdatedAt: secondTermNow.subtract(const Duration(hours: 2)),
          changeRulesUpdatedAt: secondTermNow.subtract(
            const Duration(hours: 2),
          ),
          courses: const [
            CourseEntry(
              courseName: '数据结构',
              teacherName: '周老师',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-2周',
              classroom: 'E101',
              campus: '梁林校区',
              typeSymbol: '',
            ),
          ],
        ),
        confirmedCurrentTerm: secondTerm,
        semesterStartDate: secondTermStart,
        at: secondTermNow,
      );

      expect(occurrences, hasLength(2));
      expect(occurrences[0].startMillis, shanghaiMillis(2026, 3, 2, 8, 0));
      expect(occurrences[1].startMillis, shanghaiMillis(2026, 3, 9, 8, 0));

      expectFailure(
        CalendarProjectionFailure.termMismatch,
        snapshotWith(
          termContext: const ScheduleTermContext(academicYear: 2025, term: 3),
        ),
        confirmedCurrentTerm: secondTerm,
        semesterStartDate: secondTermStart,
        at: secondTermNow,
      );
    });
  });
}
