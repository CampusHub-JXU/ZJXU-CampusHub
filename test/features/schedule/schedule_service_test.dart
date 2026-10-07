import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/semester/current_term_resolver.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/academic/effective_week_courses.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_http_client_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await ScheduleService.instance.restoreCache();
    await ScheduleService.instance.debugClearCache();
    await CurrentTermResolver.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    AcademicAuthGuard.debugAutomaticLoginOverride = null;
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
    ScheduleService.debugBeforePersistWrite = null;
    ConnectModeResolver.instance.debugReset();
    ConnectModeResolver.instance.directReachabilityChecker = () async => false;
    ConnectModeResolver.instance.webVpnReachabilityChecker = () async => false;
    DioClient.instance.debugUseMemoryCookieStorage = true;
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'jxuc_schedule_service_test/$folderName/';
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
  });

  tearDown(() {
    AcademicAuthGuard.debugAutomaticLoginOverride = null;
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
    ScheduleService.debugBeforePersistWrite = null;
    ConnectModeResolver.instance.debugReset();
  });

  /// 每个需要教务身份的用例都显式建立「当前已登录 owner」。
  void loginAs(String studentId) {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: studentId);
  }

  /// 模拟一次**真实**教务提交：推进持久 epoch + 强制 bump revision，返回
  /// typed receipt。guard 只认这种有来源证明的 committed；旧的 enum-only
  /// 桩没有 receipt，guard 会按设计 fail closed。
  Future<AutomaticLoginAttemptResult> commitAcademicSession(
    String account,
  ) async {
    final epoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.academic,
    );
    final receipt = await AuthSessionPersistence.instance.commit(
      CredentialSessionDomain.academic,
      account: account,
      expectedEpoch: epoch,
    );
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: account,
      forceRevision: true,
    );
    return AutomaticLoginAttemptResult(
      outcome: AutomaticLoginOutcome.committed,
      receipt: receipt,
    );
  }

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
    test('matches cache by exact student and term for the verified owner', () {
      const currentTerm = ScheduleTermContext(academicYear: 2025, term: 12);
      const otherTerm = ScheduleTermContext(academicYear: 2025, term: 3);

      loginAs('20230001');
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
      // 显式学号与当前登录账号不符：拒绝跨账号缓存，绝不返回 B 的课表。
      expect(
        ScheduleService.instance.preferredSnapshot(
          studentId: '20230002',
          termContext: currentTerm,
        ),
        isNull,
      );
      // 不传学号时用当前已验证账号，而不是任何「上次学号」。
      expect(
        ScheduleService.instance
            .preferredSnapshot(termContext: currentTerm)
            ?.courses
            .single
            .courseName,
        'A班课表',
      );
    });

    test(
      'returns no private cache and makes zero requests without login',
      () async {
        const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
        ScheduleService.instance.debugSetSnapshot(
          ScheduleCacheSnapshot(
            studentId: '20230001',
            termContext: termContext,
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
            scheduleUpdatedAt: DateTime.now(),
          ),
        );
        final adapter = MockHttpClientAdapter();
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
          termContext: termContext,
        );

        expect(result.requiresLogin, isTrue);
        expect(result.snapshot, isNull);
        expect(result.usedCache, isFalse);
        expect(adapter.requestLog, isEmpty, reason: '未登录必须零请求');
        expect(
          ScheduleService.instance.preferredSnapshot(
            studentId: '20230001',
            termContext: termContext,
          ),
          isNull,
          reason: '未登录不得读取任何私有缓存',
        );
      },
    );

    test('returns cached snapshot without age-based refresh', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
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

    test('keeps old cache visible for the verified owner', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
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

    test('refreshes expired current change rules instead of hiding behind cache fast path', () async {
      final termContext = ScheduleTermContext.current();
      loginAs('20230001');
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
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'POST',
          '/jwglxt/xtgl/index_cxDbsy.html',
          '<div data-tkxx="调课提醒:原定李老师第6周星期二第3-4节于102上的未知课程停课"></div>',
          headers: {
            Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
          },
        )
        ..registerText(
          'POST',
          '/jwglxt/xtgl/index_cxAreaThree.html',
          '',
          headers: {
            Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
          },
        );
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );

      expect(adapter.requestLog, [
        'POST /jwglxt/xtgl/index_cxDbsy.html',
        'POST /jwglxt/xtgl/index_cxAreaThree.html',
      ], reason: '过期调课规则必须回源，不能被缓存快路径吞掉');
      expect(result.requiresLogin, isFalse);
      expect(result.usedCache, isTrue);
      expect(result.didRefresh, isTrue);
      expect(result.snapshot?.changeRules, hasLength(1));
    });

    test(
      'hides cache and refuses network when forced refresh has no login',
      () async {
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
            scheduleUpdatedAt: DateTime.now().subtract(
              const Duration(days: 30),
            ),
            changeRulesUpdatedAt: DateTime.now().subtract(
              const Duration(days: 2),
            ),
          ),
        );
        final adapter = MockHttpClientAdapter();
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
          termContext: termContext,
          forceRefresh: true,
        );

        expect(result.requiresLogin, isTrue);
        expect(result.usedCache, isFalse);
        expect(result.snapshot, isNull, reason: '未登录时不得展示旧私有课表');
        expect(adapter.requestLog, isEmpty, reason: '未登录必须零请求');
      },
    );
  });

  group('ScheduleService auto term resolution', () {
    test(
      'falls back to previous term cache when current term has no data',
      () async {
        final previous = ScheduleTermContext.current().previous();
        loginAs('20230001');
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
        final adapter = MockHttpClientAdapter();
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

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
      loginAs('20230001');
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
      final adapter = MockHttpClientAdapter();
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

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
        loginAs('20230001');
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

    test(
      'normal AreaThree HTML mentioning 登录/session is not treated as expiry',
      () async {
        final current = ScheduleTermContext.current();
        loginAs('20230001');
        // 真实首页消息区会出现「登录」等字样（通知正文、导航、脚本变量）：
        // 不是登录页，不得被判为过期而撤销刚建立的会话。
        const areaThreeHtml = '''
<div class="list-group"><a>请同学们登录教务系统确认选课结果</a></div>
<script>var sessionUserKey = "x"; // 重新登录后生效</script>
''';
        final adapter = MockHttpClientAdapter()
          ..registerJson('POST', '/jwglxt/xtgl/index_cxDbsy.html', {
            'items': <dynamic>[],
          })
          ..registerText(
            'POST',
            '/jwglxt/xtgl/index_cxAreaThree.html',
            areaThreeHtml,
            headers: {
              Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
            },
          );
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.fetchCourseChangeRules(
          '20230001',
          termContext: current,
        );

        expect(result, isEmpty);
        expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
        expect(adapter.requestLog, [
          'POST /jwglxt/xtgl/index_cxDbsy.html',
          'POST /jwglxt/xtgl/index_cxAreaThree.html',
        ]);
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
        loginAs('20230001');
        ScheduleService.instance.debugSetSnapshot(
          ScheduleCacheSnapshot(
            studentId: '20230001',
            termContext: previous,
            changeRulesUpdatedAt: DateTime.now(),
          ),
        );
        final adapter = MockHttpClientAdapter();
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
        );

        expect(result.snapshot, isNull);
        expect(result.effectiveTermContext, isNull);
      },
    );

    test('preserves raw historical rules and unknown rules', () async {
      final previous = ScheduleTermContext.current().previous();
      loginAs('20230001');
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
      loginAs('20230001');
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
      loginAs('20230001');
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
        loginAs('20230001');
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
          buildEffectiveWeekCourses(
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

      final effective = buildEffectiveWeekCourses(
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

      final effective = buildEffectiveWeekCourses(
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
      expect(reflected.rule.classroom, '博学楼(8号楼)501');
      expect(reflected.effectiveCourse?.classroom, '博学楼(8号楼)501');
      expect(reflected.termContext, isNull);

      final unapplied = notices.firstWhere(
        (notice) => notice.rawMessage == pendingNotice,
      );
      expect(unapplied.status, CourseChangeNoticeStatus.unapplied);
      expect(unapplied.statusDetail, '学期未确认，未应用');

      final effective = buildEffectiveWeekCourses(
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

      final weekCourses = buildEffectiveWeekCourses(
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

      final week17Courses = buildEffectiveWeekCourses(
        courses: baseCourses,
        week: 17,
        changeRules: rules,
      );
      final week16Courses = buildEffectiveWeekCourses(
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

  group('ScheduleService academic auth guard', () {
    const jsonHeaders = <String, List<String>>{
      Headers.contentTypeHeader: ['application/json'],
    };

    void seedScheduleAwaitingRules(ScheduleTermContext context) {
      ScheduleService.instance.debugSetSnapshot(
        ScheduleCacheSnapshot(
          studentId: '20230001',
          termContext: context,
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
          scheduleUpdatedAt: DateTime.now(),
        ),
      );
    }

    Future<void> waitUntilSent(MockHttpClientAdapter adapter) async {
      while (adapter.requestLog.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    test('main POST 901 with manualRequired pauses without retrying', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      // 真实场景的登录态是持久提交过的；只设内存态会让条件撤销无可撤销对象，
      // 与生产语义不符。
      await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.academic,
        account: '20230001',
        expectedEpoch: 0,
      );
      loginAs('20230001');
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            expect(domain, AuthRecoveryDomain.academic);
            return AutomaticLoginOutcome.manualRequired;
          };
      final adapter = MockHttpClientAdapter()
        ..registerJson('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', {
          'code': 901,
        }, statusCode: 901);
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );

      expect(result.requiresLogin, isTrue);
      expect(result.automaticLoginPaused, isTrue);
      expect(result.snapshot, isNull);
      expect(autoLoginCalls, 1, reason: '静默 OCR/自动登录至多一次');
      expect(
        adapter.requestLog.where((r) => r.contains('xskbcx_cxXsKb')).length,
        1,
        reason: '暂停后不得再重发主 POST',
      );
      expect(
        ZhengfangAuth.instance.isLoggedIn,
        isFalse,
        reason: '暂停语义下原会话已被条件撤销，不得留下虚假登录态',
      );
    });

    test(
      'main POST 901 then committed auto-login retries at most once',
      () async {
        const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
        loginAs('20230001');
        var autoLoginCalls = 0;
        AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
            (domain, {String? expectedAccount}) async {
              autoLoginCalls++;
              return commitAcademicSession('20230001');
            };
        final adapter = MockHttpClientAdapter()
          ..registerJson('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', {
            'code': 901,
          }, statusCode: 901);
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
          termContext: termContext,
        );

        expect(autoLoginCalls, 1);
        expect(
          adapter.requestLog.where((r) => r.contains('xskbcx_cxXsKb')).length,
          2,
          reason: 'guard 原始请求 + 至多一次重试',
        );
        expect(result.requiresLogin, isTrue);
        expect(result.automaticLoginPaused, isFalse);
        // 重试仍 901：服务端确认本次 receipt 也已失效，条件撤销收尾。
        expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
      },
    );

    test('guard recovery advancing revision persists its receipt-proven retry without a third query', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
      var postCalls = 0;
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            // 模拟 guard 自动登录：同账号重登并从唯一提交点取得真实 receipt。
            return commitAcademicSession('20230001');
          };
      final adapter = MockHttpClientAdapter()
        ..register('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', (options) async {
          postCalls++;
          if (postCalls == 1) {
            return ResponseBody.fromString(
              '{"code":901}',
              901,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            );
          }
          if (postCalls == 2) {
            // guard 重试绑定本次 receipt，可直接落盘。
            return ResponseBody.fromString(
              jsonEncode(_scheduleJson([_courseJson('新会话课程')])),
              200,
              headers: jsonHeaders,
            );
          }
          return ResponseBody.fromString(
            jsonEncode(_scheduleJson([_courseJson('新会话课程')])),
            200,
            headers: jsonHeaders,
          );
        });
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );

      expect(autoLoginCalls, 1);
      expect(postCalls, 2, reason: '原始 POST + receipt 证明的唯一重试');
      expect(result.didRefresh, isTrue);
      expect(result.snapshot?.courses.single.courseName, '新会话课程');
      expect(
        result.settledRevision,
        ZhengfangAuth.instance.sessionRevision,
        reason: '返回的必须是已验证的 settled revision',
      );

      await ScheduleService.instance.restoreCache();
      final restored = ScheduleService.instance.preferredSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );
      expect(restored?.courses.single.courseName, '新会话课程');
      expect(
        restored?.courses.any((course) => course.courseName == '旧会话课程'),
        isFalse,
        reason: '旧 revision 的响应不得落盘',
      );
    });

    test('guard recovery advancing revision still falls back with the settled revision', () async {
      final previous = ScheduleTermContext.current().previous();
      loginAs('20230001');
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
          scheduleUpdatedAt: DateTime.now(),
          changeRulesUpdatedAt: DateTime.now(),
        ),
      );
      var postCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            return commitAcademicSession('20230001');
          };
      final adapter = MockHttpClientAdapter()
        ..register('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', (options) async {
          postCalls++;
          if (postCalls == 1) {
            return ResponseBody.fromString(
              '{"code":901}',
              901,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            );
          }
          // 新会话下的查询失败：当前学期无数据，应回退上一学期。
          return ResponseBody.fromString(
            '{"error":"boom"}',
            500,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
      );

      expect(
        result.effectiveTermContext,
        previous,
        reason: '必须用 settled revision 做回退判定，不能误判为身份变化',
      );
      expect(result.snapshot?.courses.single.courseName, '上学期课表');
    });

    test('expired change-rule inbox stops before AreaThree and does not log out by itself', () async {
      final current = ScheduleTermContext.current();
      loginAs('20230001');
      final adapter = MockHttpClientAdapter()
        ..registerJson('POST', '/jwglxt/xtgl/index_cxDbsy.html', {
          'code': 901,
        }, statusCode: 901);
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await expectLater(
        ScheduleService.instance.fetchCourseChangeRules(
          '20230001',
          termContext: current,
        ),
        throwsA(isA<ScheduleAuthExpiredException>()),
      );

      expect(adapter.requestLog, [
        'POST /jwglxt/xtgl/index_cxDbsy.html',
      ], reason: 'inbox 过期即停止，不得再发 AreaThree');
      expect(
        ZhengfangAuth.instance.isLoggedIn,
        isTrue,
        reason: '惰性 fetchCourseChangeRules 自身不得登出',
      );
    });

    test('late change-rule inbox after an account switch is rejected without logging out the new account', () async {
      final current = ScheduleTermContext.current();
      loginAs('20230001');
      final completer = Completer<ResponseBody>();
      final adapter = MockHttpClientAdapter()
        ..register(
          'POST',
          '/jwglxt/xtgl/index_cxDbsy.html',
          (options) => completer.future,
        );
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final future = ScheduleService.instance.fetchCourseChangeRules(
        '20230001',
        termContext: current,
      );
      await waitUntilSent(adapter);

      // 请求在途时外部切到 B。
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20230002',
      );
      completer.complete(
        ResponseBody.fromString(
          jsonEncode({'items': <dynamic>[]}),
          200,
          headers: jsonHeaders,
        ),
      );

      await expectLater(future, throwsA(isA<ScheduleAuthExpiredException>()));
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, '20230002');
    });

    test('late change-rule expiry cannot revoke a newly committed session for the same account', () async {
      final current = ScheduleTermContext.current();
      final auth = ZhengfangAuth.instance;
      await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.academic,
        account: '20230001',
        expectedEpoch: 0,
      );
      loginAs('20230001');
      seedScheduleAwaitingRules(current);
      final inbox = Completer<ResponseBody>();
      final adapter = MockHttpClientAdapter()
        ..register(
          'POST',
          '/jwglxt/xtgl/index_cxDbsy.html',
          (_) => inbox.future,
        );
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final pending = ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: current,
      );
      await waitUntilSent(adapter);
      final oldRevision = auth.sessionRevision;
      final nextEpoch = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.academic,
      );
      final newSession = await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.academic,
        account: '20230001',
        expectedEpoch: nextEpoch,
      );
      auth.debugSetSession(
        active: true,
        studentId: '20230001',
        forceRevision: true,
      );
      expect(auth.sessionRevision, greaterThan(oldRevision));
      inbox.complete(
        ResponseBody.fromString('{"code":901}', 901, headers: jsonHeaders),
      );

      final result = await pending;
      expect(result.requiresLogin, isTrue);
      expect(result.snapshot, isNull, reason: '旧调课结果不可在新会话显示旧课表');
      expect(auth.isLoggedIn, isTrue, reason: '旧请求不得登出同账号新会话');
      expect(auth.currentStudentId, '20230001');
      final durable = await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.academic,
      );
      expect(durable.active, isTrue);
      expect(durable.epoch, newSession!.epoch);
      expect(adapter.requestLog, ['POST /jwglxt/xtgl/index_cxDbsy.html']);
    });

    test(
      'current change-rule expiry revokes only its own durable session',
      () async {
        final current = ScheduleTermContext.current();
        await AuthSessionPersistence.instance.commit(
          CredentialSessionDomain.academic,
          account: '20230001',
          expectedEpoch: 0,
        );
        loginAs('20230001');
        seedScheduleAwaitingRules(current);
        final adapter = MockHttpClientAdapter()
          ..registerJson('POST', '/jwglxt/xtgl/index_cxDbsy.html', {
            'code': 901,
          }, statusCode: 901);
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
          termContext: current,
        );
        expect(result.requiresLogin, isTrue);
        expect(result.snapshot, isNull);
        expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
        final durable = await AuthSessionPersistence.instance.read(
          CredentialSessionDomain.academic,
        );
        expect(durable.active, isFalse);
        expect(adapter.requestLog, ['POST /jwglxt/xtgl/index_cxDbsy.html']);
      },
    );

    test('external account switch during the schedule request drops the response without logging out the new account', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
      final completer = Completer<ResponseBody>();
      final adapter = MockHttpClientAdapter()
        ..register(
          'POST',
          '/jwglxt/kbcx/xskbcx_cxXsKb.html',
          (options) => completer.future,
        );
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final future = ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );
      await waitUntilSent(adapter);

      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20230002',
      );
      completer.complete(
        ResponseBody.fromString(
          jsonEncode(_scheduleJson([_courseJson('A的课程')])),
          200,
          headers: jsonHeaders,
        ),
      );

      final result = await future;
      expect(result.requiresLogin, isTrue);
      expect(result.snapshot, isNull, reason: '不得把 A 的响应展示给 B');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, '20230002');
    });

    test(
      'previous-term fallback never triggers a second guard/OCR round',
      () async {
        loginAs('20230001');
        var autoLoginCalls = 0;
        AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
            (domain, {String? expectedAccount}) async {
              autoLoginCalls++;
              return commitAcademicSession('20230001');
            };
        var postCalls = 0;
        final adapter = MockHttpClientAdapter()
          ..register('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', (
            options,
          ) async {
            postCalls++;
            if (postCalls == 1) {
              // 当前学期主 POST 首次命中 901。
              return ResponseBody.fromString(
                '{"code":901}',
                901,
                headers: jsonHeaders,
              );
            }
            if (postCalls == 2) {
              // guard 自动登录后的重试仍失败：当前学期拿不到数据，触发回退。
              return ResponseBody.fromString(
                '{"error":"boom"}',
                500,
                headers: jsonHeaders,
              );
            }
            // 上一学期回退：不带 guard 的原始查询命中认证失效。
            return ResponseBody.fromString(
              '{"code":901}',
              901,
              headers: jsonHeaders,
            );
          });
        await DioClient.instance.ensureInitialized();
        DioClient.instance.dio.httpClientAdapter = adapter;

        final result = await ScheduleService.instance.loadScheduleSnapshot(
          studentId: '20230001',
        );

        expect(autoLoginCalls, 1, reason: '整次加载（含上一学期回退）至多一轮 guard/OCR');
        expect(
          adapter.requestLog.where((r) => r.contains('xskbcx_cxXsKb')).length,
          3,
          reason: '主 POST + guard 重试 + 至多一次不带 guard 的回退查询',
        );
        expect(result.snapshot, isNull);
        expect(result.effectiveTermContext, isNull);
        expect(
          ZhengfangAuth.instance.isLoggedIn,
          isTrue,
          reason: '回退查询失效不得二次登出',
        );
      },
    );

    test('serializes full-map writes so a late old-account write cannot clobber the new account', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
      final firstWriteGate = Completer<void>();
      var entered = 0;
      ScheduleService.debugBeforePersistWrite = () {
        entered++;
        if (entered == 1) return firstWriteGate.future;
        return Future<void>.value();
      };
      addTearDown(() => ScheduleService.debugBeforePersistWrite = null);

      final adapter = MockHttpClientAdapter()
        ..register('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', (options) async {
          final su = options.uri.queryParameters['su'];
          final name = su == '20230002' ? 'B课程' : 'A课程';
          return ResponseBody.fromString(
            jsonEncode(_scheduleJson([_courseJson(name)])),
            200,
            headers: jsonHeaders,
          );
        });
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final futureA = ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );
      // 等到 A 已进入持久写入临界区并被阻塞。
      while (entered == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      // 切到 B 并发起 B 的加载：B 的整 map 写入必须排在 A 之后。
      loginAs('20230002');
      final futureB = ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230002',
        termContext: termContext,
      );
      // 确保 B 已发出请求并尝试进入持久写入。
      while (adapter.requestLog
              .where((r) => r.contains('xskbcx_cxXsKb'))
              .length <
          2) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(entered, 1, reason: 'B 的整 map 写入必须等待 A 完成（同键串行）');

      firstWriteGate.complete();
      await futureA;
      await futureB;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('zjxu_schedule_cache_snapshots_v1') ?? '';
      expect(
        raw,
        contains('20230002|'),
        reason: 'B 的缓存必须存在，不被迟到的旧 A 整 map 写覆盖',
      );
      await ScheduleService.instance.restoreCache();
      expect(
        ScheduleService.instance
            .preferredSnapshot(studentId: '20230002', termContext: termContext)
            ?.courses
            .single
            .courseName,
        'B课程',
      );
    });

    test(
      'in-flight join cleans up after a throwing loader and allows a retry',
      () async {
        final unhandled = <Object>[];
        await runZonedGuarded(() async {
          final first = ScheduleService.instance.debugLoadOrJoin(
            'schedule-inflight-cleanup-test',
            () async => throw StateError('boom'),
          );
          await expectLater(first, throwsStateError);
          await Future<void>.delayed(const Duration(milliseconds: 1));

          var calls = 0;
          final second = ScheduleService.instance.debugLoadOrJoin(
            'schedule-inflight-cleanup-test',
            () async {
              calls++;
              return const ScheduleLoadResult(usedCache: true);
            },
          );
          expect(await second, isA<ScheduleLoadResult>());
          expect(calls, 1, reason: '异常后 inflight 已清理，可再次请求');
        }, (error, stack) => unhandled.add(error));

        expect(unhandled, isEmpty, reason: '不得产生未处理的 Future 异常');
      },
    );

    test('same-account re-login advancing revision rejects the old response; the next caller queries the new session', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
      final revisionBefore = ZhengfangAuth.instance.sessionRevision;
      var postCalls = 0;
      final firstGate = Completer<ResponseBody>();
      final adapter = MockHttpClientAdapter()
        ..register('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', (options) {
          postCalls++;
          if (postCalls == 1) return firstGate.future;
          return Future<ResponseBody>.value(
            ResponseBody.fromString(
              jsonEncode(_scheduleJson([_courseJson('新会话课程')])),
              200,
              headers: jsonHeaders,
            ),
          );
        });
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final future = ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );
      await waitUntilSent(adapter);

      // 模拟成功提交同账号新会话；全程保持 active A，不经过登出空窗。
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20230001',
        forceRevision: true,
      );
      expect(
        ZhengfangAuth.instance.sessionRevision,
        greaterThan(revisionBefore),
      );

      // 旧 revision 的响应返回：不得被直接采纳，必须在新 revision 下重查。
      firstGate.complete(
        ResponseBody.fromString(
          jsonEncode(_scheduleJson([_courseJson('旧会话课程')])),
          200,
          headers: jsonHeaders,
        ),
      );

      final stale = await future;
      expect(postCalls, 1, reason: '旁路登录没有本请求 receipt，禁止隐式重放');
      expect(stale.didRefresh, isFalse);
      expect(stale.snapshot, isNull);
      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
        forceRefresh: true,
      );
      expect(postCalls, 2);
      expect(result.snapshot?.courses.single.courseName, '新会话课程');
      await ScheduleService.instance.restoreCache();
      expect(
        ScheduleService.instance
            .preferredSnapshot(studentId: '20230001', termContext: termContext)
            ?.courses
            .single
            .courseName,
        '新会话课程',
      );
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, '20230001');
    });

    test('persists refreshed schedule only under the verified owner', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
      final adapter = MockHttpClientAdapter()
        ..registerJson(
          'POST',
          '/jwglxt/kbcx/xskbcx_cxXsKb.html',
          _scheduleJson([_courseJson('本人课程')]),
        );
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );
      expect(result.didRefresh, isTrue);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('zjxu_schedule_cache_snapshots_v1') ?? '';
      expect(
        raw,
        contains('20230001|${termContext.academicYear}|${termContext.term}'),
      );

      // 切到 B 后不得从磁盘复活 A 的课表。
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20230002',
      );
      await ScheduleService.instance.restoreCache();
      expect(
        ScheduleService.instance.preferredSnapshot(
          studentId: '20230002',
          termContext: termContext,
        ),
        isNull,
      );
    });

    // 期望终态（配合 core guard/zhengfang 的 revision + 条件登出修复）：guard
    // 恢复期间并发外部换号到 B 时，绝不登出新账号 B；旧 A 的响应既不展示也不
    // 落盘。core 未终态前本用例可能失败，需在 core 终态后联测。
    test('external switch during recovery keeps the new account and never shows or caches the old response', () async {
      const termContext = ScheduleTermContext(academicYear: 2025, term: 12);
      loginAs('20230001');
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            // 模拟并发外部换号：自动登录期间身份已切到 B。
            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: '20230002',
            );
            return AutomaticLoginOutcome.committed;
          };
      final adapter = MockHttpClientAdapter()
        ..registerJson('POST', '/jwglxt/kbcx/xskbcx_cxXsKb.html', {
          'code': 901,
        }, statusCode: 901);
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;

      final result = await ScheduleService.instance.loadScheduleSnapshot(
        studentId: '20230001',
        termContext: termContext,
      );

      expect(result.requiresLogin, isTrue);
      expect(result.snapshot, isNull, reason: '不得把 A 的响应展示给 B');
      expect(
        ZhengfangAuth.instance.isLoggedIn,
        isTrue,
        reason: '不得登出期间切入的新账号 B',
      );
      expect(ZhengfangAuth.instance.currentStudentId, '20230002');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('zjxu_schedule_cache_snapshots_v1') ?? '';
      expect(raw.contains('20230001|'), isFalse, reason: '旧 A 响应不得落盘');
      expect(
        ScheduleService.instance.preferredSnapshot(
          studentId: '20230002',
          termContext: termContext,
        ),
        isNull,
      );
    });
  });
}

Map<String, dynamic> _scheduleJson(List<Map<String, dynamic>> kbList) => {
  'xsxx': <String, dynamic>{},
  'kbList': kbList,
};

Map<String, dynamic> _courseJson(
  String courseName, {
  String classroom = '101',
}) => {
  'kcmc': courseName,
  'xm': '教师A',
  'xqj': '1',
  'jcs': '1-2',
  'zcd': '1-18周',
  'cdmc': classroom,
  'xqmc': '嘉兴校区',
  'xslxbj': '',
};
