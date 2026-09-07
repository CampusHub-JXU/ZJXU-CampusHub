import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:jxu_campus_hub/core/semester/current_term_resolver.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_http_client_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ScheduleService.instance.restoreCache();
    await ScheduleService.instance.debugClearCache();
    await CurrentTermResolver.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
  });

  group('ScheduleCacheSnapshot', () {
    test('round-trips course and change rule data', () {
      final snapshot = ScheduleCacheSnapshot(
        studentId: '20230001',
        termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
        courses: const [
          CourseEntry(
            courseName: 'AI+创新创业基础',
            teacherName: '胡亚楠',
            weekday: 5,
            startLesson: 8,
            endLesson: 9,
            weekRange: '1-18周',
            classroom: '铭德楼468',
            campus: '梁林校区',
            typeSymbol: '',
          ),
        ],
        changeRules: const [
          CourseChangeRule(
            type: CourseChangeType.reschedule,
            originalLesson: CourseLessonSlot(
              week: 5,
              weekday: 4,
              startLesson: 8,
              endLesson: 9,
            ),
            targetLesson: CourseLessonSlot(
              week: 5,
              weekday: 5,
              startLesson: 8,
              endLesson: 9,
            ),
            courseName: 'AI+创新创业基础',
            teacherName: '胡亚楠',
            classroom: '铭德楼468',
          ),
        ],
        scheduleUpdatedAt: DateTime(2026, 4, 8, 8, 0),
        changeRulesUpdatedAt: DateTime(2026, 4, 8, 9, 30),
      );

      final restored = ScheduleCacheSnapshot.fromJson(snapshot.toJson());

      expect(restored.studentId, snapshot.studentId);
      expect(restored.termContext.academicYear, 2025);
      expect(restored.termContext.term, 12);
      expect(restored.courses.single.courseName, 'AI+创新创业基础');
      expect(restored.changeRules.single.type, CourseChangeType.reschedule);
      expect(restored.changeRules.single.targetLesson?.weekday, 5);
      expect(restored.lastUpdatedAt, DateTime(2026, 4, 8, 9, 30));
    });

    test('detects stale schedule and change rules with explicit windows', () {
      final snapshot = ScheduleCacheSnapshot(
        studentId: '20230001',
        termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
        scheduleUpdatedAt: DateTime(2026, 4, 1, 8, 0),
        changeRulesUpdatedAt: DateTime(2026, 4, 7, 8, 0),
      );

      expect(
        snapshot.needsScheduleRefresh(
          DateTime(2026, 4, 8, 8, 0),
          maxAge: const Duration(days: 7),
        ),
        isTrue,
      );
      expect(
        snapshot.needsChangeRulesRefresh(
          DateTime(2026, 4, 8, 8, 0),
          maxAge: const Duration(days: 1),
        ),
        isTrue,
      );
      expect(
        snapshot.needsChangeRulesRefresh(
          DateTime(2026, 4, 7, 20, 0),
          maxAge: const Duration(days: 1),
        ),
        isFalse,
      );
    });
  });

  group('ScheduleService cache selection', () {
    test('matches cache by exact student and term', () {
      const currentTerm = ScheduleTermContext(academicYear: 2025, term: 12);
      const otherTerm = ScheduleTermContext(academicYear: 2025, term: 3);

      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: currentTerm,
          courses: const [
            CourseEntry(
              courseName: 'A班课表',
              teacherName: '教师A',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-18周',
              classroom: '101',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          scheduleUpdatedAt: DateTime(2026, 4, 8, 8, 0),
        ),
      );
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: otherTerm,
          courses: const [
            CourseEntry(
              courseName: '上学期课表',
              teacherName: '教师B',
              weekday: 2,
              startLesson: 3,
              endLesson: 4,
              weekRange: '1-18周',
              classroom: '202',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          scheduleUpdatedAt: DateTime(2026, 4, 8, 8, 0),
        ),
      );
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230002',
          termContext: currentTerm,
          courses: const [
            CourseEntry(
              courseName: 'B班课表',
              teacherName: '教师C',
              weekday: 3,
              startLesson: 5,
              endLesson: 6,
              weekRange: '1-18周',
              classroom: '303',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          scheduleUpdatedAt: DateTime(2026, 4, 8, 8, 0),
        ),
      );

      expect(
        ScheduleService.instance
            .preferredSnapshot(studentId: '20230001', termContext: currentTerm)
            ?.courses
            .single
            .courseName,
        'A班课表',
      );
      expect(
        ScheduleService.instance
            .preferredSnapshot(studentId: '20230001', termContext: otherTerm)
            ?.courses
            .single
            .courseName,
        '上学期课表',
      );
      expect(
        ScheduleService.instance
            .preferredSnapshot(studentId: '20230002', termContext: currentTerm)
            ?.courses
            .single
            .courseName,
        'B班课表',
      );
    });

    test('returns cached snapshot without age-based refresh', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: termContext,
          courses: const [
            CourseEntry(
              courseName: '缓存课表',
              teacherName: '教师A',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-18周',
              classroom: '101',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          scheduleUpdatedAt: DateTime.now(),
        ),
      );

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );

      expect(result.usedCache, isTrue);
      expect(result.didRefresh, isFalse);
      expect(result.snapshot?.courses.single.courseName, '缓存课表');
    });

    test('keeps old cache visible without requiring login', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: termContext,
          courses: const [
            CourseEntry(
              courseName: '旧课表',
              teacherName: '教师A',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-18周',
              classroom: '101',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          scheduleUpdatedAt: DateTime.now().subtract(const Duration(days: 30)),
          changeRulesUpdatedAt: DateTime.now().subtract(
            const Duration(days: 2),
          ),
        ),
      );

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );

      expect(result.requiresLogin, isFalse);
      expect(result.usedCache, isTrue);
      expect(result.snapshot?.courses.single.courseName, '旧课表');
      expect(result.message, isNull);
    });

    test(
      'does not hide expired current change rules behind cache fast path',
      () async {
        final termContext = ScheduleTermContext.current();
        ScheduleService.instance.debugSetSnapshot(
          ScheduleCacheSnapshot(
            studentId: '20230001',
            termContext: termContext,
            courses: const [
              CourseEntry(
                courseName: '当前课表',
                teacherName: '教师A',
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
                weekRange: '1-18周',
                classroom: '101',
                campus: '嘉兴校区',
                typeSymbol: '',
              ),
            ],
            changeRules: [
              CourseChangeRule(
                type: CourseChangeType.cancel,
                courseName: '当前课表',
                termContext: termContext,
              ),
            ],
            scheduleUpdatedAt: DateTime.now(),
            changeRulesUpdatedAt: DateTime.now().subtract(
              const Duration(days: 2),
            ),
            changeRulesCurrentScoped: true,
          ),
        );

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
          termContext: termContext,
        );

        expect(result.requiresLogin, isTrue);
        expect(result.usedCache, isTrue);
        expect(result.snapshot?.changeRules, hasLength(1));
        expect(result.message, contains('刷新'));
      },
    );

    test('keeps cache visible when forced refresh requires login', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: termContext,
          courses: const [
            CourseEntry(
              courseName: '缓存课表',
              teacherName: '教师A',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-18周',
              classroom: '101',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          scheduleUpdatedAt: DateTime.now().subtract(const Duration(days: 30)),
          changeRulesUpdatedAt: DateTime.now().subtract(
            const Duration(days: 2),
          ),
        ),
      );

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
        forceRefresh: true,
      );

      expect(result.requiresLogin, isTrue);
      expect(result.usedCache, isTrue);
      expect(result.snapshot?.courses.single.courseName, '缓存课表');
      expect(result.message, contains('缓存'));
    });
  });

  group('ScheduleService auto term resolution', () {
    test(
      'falls back to previous term cache when current term has no data',
      () async {
        final previous = ScheduleTermContext.current().previous();
        ScheduleService.instance.debugSetSnapshot(
          ScheduleCacheSnapshot(
            studentId: '20230001',
            termContext: previous,
            courses: const [
              CourseEntry(
                courseName: '上学期课表',
                teacherName: '教师A',
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
                weekRange: '1-18周',
                classroom: '101',
                campus: '嘉兴校区',
                typeSymbol: '',
              ),
            ],
            changeRules: const [
              CourseChangeRule(
                type: CourseChangeType.cancel,
                originalLesson: CourseLessonSlot(
                  week: 2,
                  weekday: 1,
                  startLesson: 1,
                  endLesson: 2,
                ),
                courseName: '上学期课表',
              ),
            ],
            changeRulesUpdatedAt: DateTime.now(),
            scheduleUpdatedAt: DateTime.now(),
          ),
        );

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
        );

        expect(result.effectiveTermContext, previous);
        expect(result.snapshot?.courses.single.courseName, '上学期课表');
        expect(result.snapshot?.changeRules, hasLength(1));
        expect(result.message, contains('上一学期'));
      },
    );

    test('returns cached current term snapshot without fallback', () async {
      final current = ScheduleTermContext.current();
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: current,
          courses: const [
            CourseEntry(
              courseName: '本学期课表',
              teacherName: '教师A',
              weekday: 2,
              startLesson: 3,
              endLesson: 4,
              weekRange: '1-18周',
              classroom: '102',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          scheduleUpdatedAt: DateTime.now(),
          changeRulesUpdatedAt: DateTime.now(),
        ),
      );

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
      );

      expect(result.effectiveTermContext, isNull);
      expect(result.snapshot?.courses.single.courseName, '本学期课表');
    });

    test('explicit term context never triggers fallback', () async {
      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: const ScheduleTermContext(academicYear: 2025, term: 3),
      );

      expect(result.requiresLogin, isTrue);
      expect(result.effectiveTermContext, isNull);
      expect(result.snapshot, isNull);
    });
  });

  group('ScheduleService change-rule term isolation', () {
    test(
      'merges inbox and AreaThree while retaining unknown messages',
      () async {
        final current = ScheduleTermContext.current();
        final termLabel = current.term == 3 ? '第1' : '第2';
        final termPrefix =
            '${current.academicYear}-${current.academicYear + 1}学年$termLabel学期';
        final inboxHtml =
            '''
<div data-tkxx="$termPrefix 停课提醒:原定王老师第5周星期一第1-2节于101上的当前课程停课"></div>
<div data-tkxx="调课提醒:原定李老师第6周星期二第3-4节于102上的未知课程停课"></div>
''';
        final areaThreeHtml =
            '''
<div data-tkxx="$termPrefix 换教室提醒:原定陈老师在第7周星期三第5-6节兴德楼101上的另一课程现改为在博学楼202上课"></div>
<div data-tkxx="补课提醒:原定赵老师第8周星期四第7-8节对课程未知课程进行补课"></div>
''';
        final adapter = MockHttpClientAdapter()
          ..registerText(
            'POST',
            '/jwglxt/xtgl/index_cxDbsy.html',
            inboxHtml,
            headers: {
              Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
            },
          )
          ..registerText(
            'POST',
            '/jwglxt/xtgl/index_cxAreaThree.html',
            areaThreeHtml,
            headers: {
              Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
            },
          );

        const pathProviderChannel = MethodChannel(
          'plugins.flutter.io/path_provider',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return Directory.systemTemp.path;
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(pathProviderChannel, null),
        );
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.fetchCourseChangeRules(
          '20230001',
          termContext: current,
        );

        expect(adapter.requestLog, [
          'POST /jwglxt/xtgl/index_cxDbsy.html',
          'POST /jwglxt/xtgl/index_cxAreaThree.html',
        ]);
        expect(result, hasLength(4));
        expect(
          result.where((rule) => rule.termContext == current),
          hasLength(2),
        );
        expect(result.where((rule) => rule.termContext == null), hasLength(2));
      },
    );

    test('does not request unscoped rules for a history term', () async {
      final previous = ScheduleTermContext.current().previous();

      expect(
        (await ScheduleService.instance.fetchCourseChangeRules(
          '20230001',
          termContext: previous,
        )),
        isEmpty,
      );
    });

    test(
      'does not let a rules timestamp-only history snapshot block fallback',
      () async {
        final previous = ScheduleTermContext.current().previous();
        ScheduleService.instance.debugSetSnapshot(
          ScheduleCacheSnapshot(
            studentId: '20230001',
            termContext: previous,
            changeRulesUpdatedAt: DateTime.now(),
          ),
        );

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
        );

        expect(result.snapshot, isNull);
        expect(result.effectiveTermContext, isNull);
      },
    );

    test('preserves raw historical rules and unknown rules', () async {
      final previous = ScheduleTermContext.current().previous();
      final validRule = CourseChangeRule(
        type: CourseChangeType.cancel,
        originalLesson: const CourseLessonSlot(
          week: 2,
          weekday: 1,
          startLesson: 1,
          endLesson: 2,
        ),
        courseName: '历史课表',
        termContext: previous,
      );
      final snapshot = ScheduleCacheSnapshot(
        studentId: '20230001',
        termContext: previous,
        courses: const [
          CourseEntry(
            courseName: '历史课表',
            teacherName: '教师A',
            weekday: 1,
            startLesson: 1,
            endLesson: 2,
            weekRange: '1-18周',
            classroom: '101',
            campus: '嘉兴校区',
            typeSymbol: '',
          ),
        ],
        changeRules: [
          validRule,
          CourseChangeRule(
            type: CourseChangeType.cancel,
            originalLesson: const CourseLessonSlot(
              week: 2,
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
            ),
            courseName: '历史课表',
          ),
        ],
        changeRulesUpdatedAt: DateTime(2026, 4, 2),
      );
      SharedPreferences.setMockInitialValues({
        'zjxu_schedule_cache_snapshots_v1': jsonEncode({
          '20230001|${previous.academicYear}|${previous.term}': snapshot
              .toJson(),
        }),
      });
      final encodedBefore = jsonEncode({
        '20230001|${previous.academicYear}|${previous.term}': snapshot.toJson(),
      });

      await ScheduleService.instance.restoreCache();

      final restored = ScheduleService.instance.preferredSnapshot(
        studentId: '20230001',
        termContext: previous,
      );
      expect(restored?.courses, isNotEmpty);
      expect(restored?.changeRules, hasLength(2));
      expect(
        restored?.changeRules.where((rule) => rule.termContext == previous),
        hasLength(1),
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          'zjxu_schedule_cache_snapshots_v1',
        ),
        encodedBefore,
      );
    });

    test('shows proven and unknown history rules without applying old context', () {
      final current = ScheduleTermContext.current();
      final previous = current.previous();
      final previousTermLabel = previous.term == 3 ? '第1' : '第2';
      final provenRule = parseScheduleChangeMessages([
        '${previous.academicYear}-${previous.academicYear + 1}学年$previousTermLabel学期 停课提醒:原定王老师第5周星期一第1-2节于101上的当前课程停课',
      ]).single;
      final unknownRule = parseScheduleChangeMessages([
        '停课提醒:原定李老师第6周星期二第3-4节于102上的历史课程停课',
      ]).single;
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: previous,
          courses: const [
            CourseEntry(
              courseName: '历史课表',
              teacherName: '教师A',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-18周',
              classroom: '101',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          changeRules: [provenRule, unknownRule],
          changeRulesUpdatedAt: DateTime.now(),
          changeRulesCurrentScoped: true,
        ),
      );

      expect(
        ScheduleService.instance
            .preferredSnapshot(studentId: '20230001', termContext: previous)
            ?.changeRules,
        [provenRule, unknownRule],
      );
    });

    test('does not apply current rules without explicit term evidence', () {
      final current = ScheduleTermContext.current();
      final rule = parseScheduleChangeMessages([
        '停课提醒:原定王老师第5周星期一第1-2节于101上的当前课程停课',
      ]).single;
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: current,
          courses: const [
            CourseEntry(
              courseName: '当前课程',
              teacherName: '教师A',
              weekday: 1,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-18周',
              classroom: '101',
              campus: '嘉兴校区',
              typeSymbol: '',
            ),
          ],
          changeRules: [rule],
          changeRulesUpdatedAt: DateTime.now(),
          changeRulesCurrentScoped: true,
        ),
      );

      final snapshot = ScheduleService.instance.preferredSnapshot(
        studentId: '20230001',
        termContext: current,
      );
      expect(snapshot?.changeRules, [rule]);
    });

    test(
      'keeps explicitly current-scoped rules available for effective courses',
      () {
        final current = ScheduleTermContext.current();
        final rule = parseScheduleChangeMessages([
          '2026-2027学年第1学期 停课提醒:原定王老师第5周星期一第1-2节于101上的当前课程停课',
        ]).single;
        ScheduleService.instance.debugSetSnapshot(
          ScheduleCacheSnapshot(
            studentId: '20230001',
            termContext: current,
            courses: const [
              CourseEntry(
                courseName: '当前课程',
                teacherName: '教师A',
                weekday: 1,
                startLesson: 1,
                endLesson: 2,
                weekRange: '1-18周',
                classroom: '101',
                campus: '嘉兴校区',
                typeSymbol: '',
              ),
            ],
            changeRules: [rule],
            changeRulesUpdatedAt: DateTime.now(),
            changeRulesCurrentScoped: true,
          ),
        );

        final snapshot = ScheduleService.instance.preferredSnapshot(
          studentId: '20230001',
          termContext: current,
        );
        expect(snapshot?.changeRules, hasLength(1));
        expect(
          ScheduleService.instance.buildEffectiveWeekCourses(
            courses: snapshot!.courses,
            week: 5,
            changeRules: snapshot.changeRules,
          ),
          isEmpty,
        );
      },
    );
  });

  group('ScheduleService change notice visibility', () {
    test('filters dated historical notices for the current term only', () {
      SemesterCalendar.instance.semesterStartDate.value = DateTime(2026, 9, 1);
      const current = ScheduleTermContext(academicYear: 2026, term: 3);
      final notices = ScheduleService.instance.buildCourseChangeNotices(
        courses: const [],
        changeRules: parseScheduleChangeMessageEntries([
          ScheduleChangeMessage(
            message: '换教室提醒:原定李恒老师在第2周星期一第6-7节兴德楼南楼223上的数字经济概论课程现改为在博学楼(8号楼)501上课，请各位同学相互告知！',
            publishedAt: DateTime(2026, 9, 1, 11, 5, 7),
          ),
          ScheduleChangeMessage(
            message: '调课提醒:沈芳老师于第10周星期三第3-4节在兴德楼南楼107上的大学生职业规划与就业指导1课程调课到由沈芳老师在第10周星期三第3-4节网络平台上课，请各位同学相互告知！',
            publishedAt: DateTime(2026, 4, 29, 9, 33, 22),
          ),
        ]),
        termContext: current,
        now: DateTime(2026, 9, 7),
      );

      expect(notices, hasLength(1));
      expect(notices.single.rawMessage, contains('数字经济概论'));
    });

    test('keeps unknown-term future and historical-term notices visible', () {
      SemesterCalendar.instance.semesterStartDate.value = DateTime(2026, 9, 1);
      final message = ScheduleChangeMessage(
        message: '调课提醒:王老师于第3周星期二第1-2节在A楼101上的高等数学课程调课到由王老师在第3周星期二第1-2节B楼202上课，请各位同学相互告知！',
        publishedAt: DateTime(2099, 1, 1),
      );
      final future = ScheduleService.instance.buildCourseChangeNotices(
        courses: const [],
        changeRules: parseScheduleChangeMessageEntries([message]),
        termContext: const ScheduleTermContext(academicYear: 2026, term: 3),
        now: DateTime(2026, 9, 7),
      );
      final history = ScheduleService.instance.buildCourseChangeNotices(
        courses: const [],
        changeRules: parseScheduleChangeMessageEntries([
          ScheduleChangeMessage(
            message: message.message,
            publishedAt: DateTime(2026, 4, 29),
          ),
        ]),
        termContext: const ScheduleTermContext(academicYear: 2025, term: 12),
        now: DateTime(2026, 9, 7),
      );

      expect(future, hasLength(1));
      expect(history, hasLength(1));
    });

    test('explicit message term outranks an old publication date', () {
      SemesterCalendar.instance.semesterStartDate.value = DateTime(2026, 9, 1);
      const current = ScheduleTermContext(academicYear: 2026, term: 3);
      final notices = ScheduleService.instance.buildCourseChangeNotices(
        courses: const [],
        changeRules: parseScheduleChangeMessageEntries([
          ScheduleChangeMessage(
            message: '2026-2027学年第1学期 调课提醒:王老师于第3周星期二第1-2节在A楼101上的高等数学课程调课到由王老师在第3周星期二第1-2节B楼202上课，请各位同学相互告知！',
            publishedAt: DateTime(2026, 4, 29),
          ),
        ]),
        termContext: current,
        now: DateTime(2026, 9, 7),
      );

      expect(notices, hasLength(1));
    });

    test(
      'disables date cropping for a spring target with old autumn start',
      () {
        SemesterCalendar.instance.semesterStartDate.value = DateTime(
          2025,
          9,
          1,
        );
        final notices = ScheduleService.instance.buildCourseChangeNotices(
          courses: const [],
          changeRules: [
            CourseChangeRule(
              type: CourseChangeType.cancel,
              rawMessage: '春季历史通知',
              publishedAt: DateTime(2025, 11, 1),
            ),
          ],
          termContext: const ScheduleTermContext(academicYear: 2026, term: 12),
          now: DateTime(2026, 4, 1),
        );

        expect(notices, hasLength(1));
      },
    );

    test(
      'disables date cropping for an autumn target with old spring start',
      () {
        SemesterCalendar.instance.semesterStartDate.value = DateTime(
          2026,
          3,
          2,
        );
        final notices = ScheduleService.instance.buildCourseChangeNotices(
          courses: const [],
          changeRules: [
            CourseChangeRule(
              type: CourseChangeType.cancel,
              rawMessage: '秋季目标的旧春季通知',
              publishedAt: DateTime(2026, 4, 29),
            ),
          ],
          termContext: const ScheduleTermContext(academicYear: 2026, term: 3),
          now: DateTime(2026, 9, 7),
        );

        expect(notices, hasLength(1));
      },
    );

    test('disables date cropping when the calendar year is wrong', () {
      SemesterCalendar.instance.semesterStartDate.value = DateTime(2025, 9, 1);
      final notices = ScheduleService.instance.buildCourseChangeNotices(
        courses: const [],
        changeRules: [
          CourseChangeRule(
            type: CourseChangeType.cancel,
            rawMessage: '错误学年通知',
            publishedAt: DateTime(2026, 4, 29),
          ),
        ],
        termContext: const ScheduleTermContext(academicYear: 2026, term: 3),
        now: DateTime(2026, 9, 7),
      );

      expect(notices, hasLength(1));
    });
  });

  group('ScheduleService.buildEffectiveWeekCourses', () {
    test('authoritative changed course wins over a stale rule target', () {
      final current = ScheduleTermContext.current();
      final rule = parseScheduleChangeMessages([
        '2026-2027学年第1学期 换教室提醒:原定李恒老师在第2周星期一第6-7节兴德楼南楼223上的数字经济概论课程现改为在博学楼202上课，请各位同学相互告知！',
      ]).single;
      const authoritativeCourse = CourseEntry(
        courseName: '数字经济概论',
        teacherName: '李恒',
        weekday: 1,
        startLesson: 6,
        endLesson: 7,
        weekRange: '2-5周,7-18周',
        classroom: '博学楼(8号楼)501',
        campus: '梁林校区',
        typeSymbol: '◆',
        hasScheduleChange: true,
      );

      final effective = ScheduleService.instance.buildEffectiveWeekCourses(
        courses: const [authoritativeCourse],
        week: 2,
        changeRules: [rule],
        termContext: current,
      );

      expect(effective, hasLength(1));
      expect(effective.single.classroom, '博学楼(8号楼)501');
    });

    test('requires every expanded week to be represented by the schedule', () {
      final current = ScheduleTermContext.current();
      final rules = parseScheduleChangeMessages([
        '换教室提醒:原定李恒老师在第2-5周,7-18周星期一第6-7节兴德楼南楼223上的数字经济概论课程现改为在博学楼(8号楼)501上课，请各位同学相互告知！',
      ]);

      final notices = ScheduleService.instance.buildCourseChangeNotices(
        courses: const [
          CourseEntry(
            courseName: '数字经济概论',
            teacherName: '李恒',
            weekday: 1,
            startLesson: 6,
            endLesson: 7,
            weekRange: '2-5周,7-17周',
            classroom: '博学楼(8号楼)501',
            campus: '梁林校区',
            typeSymbol: '◆',
            hasScheduleChange: true,
          ),
        ],
        changeRules: rules,
        termContext: current,
      );

      expect(notices, hasLength(1));
      expect(notices.single.status, CourseChangeNoticeStatus.unapplied);
    });

    test('does not treat a partial lesson overlap as reflected', () {
      final current = ScheduleTermContext.current();
      final rules = parseScheduleChangeMessages([
        '2026-2027学年第1学期 换教室提醒:原定李恒老师在第2周星期一第6-7节兴德楼南楼223上的数字经济概论课程现改为在博学楼(8号楼)501上课，请各位同学相互告知！',
      ]);

      final notices = ScheduleService.instance.buildCourseChangeNotices(
        courses: const [
          CourseEntry(
            courseName: '数字经济概论',
            teacherName: '李恒',
            weekday: 1,
            startLesson: 6,
            endLesson: 6,
            weekRange: '2-5周,7-18周',
            classroom: '博学楼(8号楼)501',
            campus: '梁林校区',
            typeSymbol: '◆',
            hasScheduleChange: true,
          ),
        ],
        changeRules: rules,
        termContext: current,
      );

      expect(notices.single.status, CourseChangeNoticeStatus.unapplied);

      final effective = ScheduleService.instance.buildEffectiveWeekCourses(
        courses: const [
          CourseEntry(
            courseName: '数字经济概论',
            teacherName: '李恒',
            weekday: 1,
            startLesson: 6,
            endLesson: 6,
            weekRange: '2-5周,7-18周',
            classroom: '博学楼(8号楼)501',
            campus: '梁林校区',
            typeSymbol: '◆',
            hasScheduleChange: true,
          ),
        ],
        week: 2,
        changeRules: rules,
        termContext: current,
      );
      expect(effective.single.classroom, '博学楼(8号楼)501');
    });

    test('refreshes stale authoritative room and exposes one reflected notice', () async {
      SemesterCalendar.instance.semesterStartDate.value = DateTime(2026, 9, 1);
      final current = ScheduleTermContext.current();
      const studentId = '20230001';
      const roomNotice =
          '换教室提醒:原定李恒老师在第2-5周,7-18周星期一第6-7节兴德楼南楼223上的数字经济概论课程现改为在博学楼(8号楼)501上课，请各位同学相互告知！';
      const oldNotice =
          '调课提醒:沈芳老师于第10周星期三第3-4节在兴德楼南楼107上的大学生职业规划与就业指导1课程调课到由沈芳老师在第10周星期三第3-4节网络平台上课，请各位同学相互告知！';
      const pendingNotice =
          '换教室提醒:原定王老师在第3周星期二第1-2节A楼101上的高等数学课程现改为在B楼202上课，请各位同学相互告知！';
      final adapter = MockHttpClientAdapter()
        ..registerJson('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', {
          'xsxx': {
            'XNM': current.academicYear.toString(),
            'XQM': current.term.toString(),
          },
          'xskbsfxstkzt': '1',
          'kbList': [
            {
              'kcmc': '数字经济概论',
              'xm': '李恒',
              'xqj': '1',
              'jcs': '6-7',
              'zcd': '2-5周,7-18周',
              'cdmc': '博学楼(8号楼)501',
              'xqmc': '梁林校区',
              'xslxbj': '◆',
              'jxbsftkbj': '1',
            },
          ],
        })
        ..registerText(
          'POST',
          '/jwglxt/xtgl/index_cxDbsy.html',
          '<a data-tkxx="$roomNotice"></a>',
          headers: {
            Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
          },
        )
        ..registerText(
          'POST',
          '/jwglxt/xtgl/index_cxAreaThree.html',
          '<a data-tkxx="$roomNotice"><span class="fraction">2026-09-01 11:05:07</span></a>'
              '<a data-tkxx="$oldNotice"><span class="fraction">2026-04-29 09:33:22</span></a>'
              '<a data-tkxx="$pendingNotice"><span class="fraction">2026-09-02 09:00:00</span></a>',
          headers: {
            Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
          },
        );

      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: studentId,
      );
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: studentId,
          termContext: current,
          courses: const [
            CourseEntry(
              courseName: '数字经济概论',
              teacherName: '李恒',
              weekday: 1,
              startLesson: 6,
              endLesson: 7,
              weekRange: '2-5周,7-18周',
              classroom: '兴德楼南楼223',
              campus: '梁林校区',
              typeSymbol: '◆',
            ),
          ],
          scheduleUpdatedAt: DateTime(2026, 8, 1),
          changeRulesUpdatedAt: DateTime(2026, 8, 1),
        ),
      );
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: studentId,
        termContext: current,
      );

      expect(result.didRefresh, isTrue);
      expect(result.message, '有1条调课提醒未在当前课表体现');
      final snapshot = result.snapshot!;
      expect(snapshot.courses.single.classroom, '博学楼(8号楼)501');
      expect(snapshot.courses.single.hasScheduleChange, isTrue);
      expect(snapshot.changeRules, hasLength(18));

      final notices = ScheduleService.instance.buildCourseChangeNotices(
        courses: snapshot.courses,
        changeRules: snapshot.changeRules,
        termContext: current,
      );
      expect(notices, hasLength(2));
      final reflected = notices.firstWhere(
        (notice) => notice.rawMessage == roomNotice,
      );
      expect(reflected.status, CourseChangeNoticeStatus.reflected);
      expect(reflected.originalClassroom, '兴德楼南楼223');
      expect(reflected.newClassroom, '博学楼(8号楼)501');
      expect(reflected.effectiveClassroom, '博学楼(8号楼)501');
      expect(reflected.termContext, isNull);

      final unapplied = notices.firstWhere(
        (notice) => notice.rawMessage == pendingNotice,
      );
      expect(unapplied.status, CourseChangeNoticeStatus.unapplied);
      expect(unapplied.statusDetail, '学期未确认，未应用');

      final effective = ScheduleService.instance.buildEffectiveWeekCourses(
        courses: snapshot.courses,
        week: 2,
        changeRules: snapshot.changeRules,
        termContext: current,
      );
      expect(effective, hasLength(1));
      expect(effective.single.classroom, '博学楼(8号楼)501');

      await ScheduleService.instance.restoreCache();
      final restored = ScheduleService.instance.preferredSnapshot(
        studentId: studentId,
        termContext: current,
      );
      expect(restored?.courses.single.classroom, '博学楼(8号楼)501');
      expect(restored?.changeRules, hasLength(18));
      expect(
        ScheduleService.instance
            .buildCourseChangeNotices(
              courses: restored!.courses,
              changeRules: restored.changeRules,
              termContext: current,
            )
            .firstWhere((notice) => notice.rawMessage == roomNotice)
            .status,
        CourseChangeNoticeStatus.reflected,
      );
    });

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

      final rules = parseScheduleChangeMessages([
        '2026-2027学年第1学期 调课提醒:胡亚楠老师于第5周星期四第8-9节在铭德楼467上的AI+创新创业基础课程调课到由胡亚楠老师在第5周星期五第8-9节在铭德楼468上的AI+创新创业基础课程，请各位同学相互告知！',
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

      final rules = parseScheduleChangeMessages([
        '2026-2027学年第1学期 补课提醒:杨月红老师将在第17周星期六第11-12节对课程健身1进行补课，请各位同学相互告知！',
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
