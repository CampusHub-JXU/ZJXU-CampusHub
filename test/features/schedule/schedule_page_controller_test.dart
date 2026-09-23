import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/features/schedule/controllers/schedule_page_controller.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownerA = '2025000001';
  const ownerB = '2025000002';

  // 与服务端持久缓存键保持一致，用于模拟「prefs 中已存在旧身份缓存」的冷启动。
  const cacheStorageKey = 'zjxu_schedule_cache_snapshots_v1';

  setUp(() async {
    await resetTestEnvironment();
    final today = DateTime.now();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      today.year,
      today.month,
      today.day,
    );
  });

  ScheduleCacheSnapshot snapshotFor(
    String studentId, {
    required String courseName,
    required ScheduleTermContext termContext,
  }) {
    return ScheduleCacheSnapshot(
      studentId: studentId,
      termContext: termContext,
      courses: [
        CourseEntry(
          courseName: courseName,
          teacherName: '教师',
          weekday: 1,
          startLesson: 1,
          endLesson: 2,
          weekRange: '1-18周',
          classroom: '101',
          campus: '梁林校区',
          typeSymbol: '',
        ),
      ],
      scheduleUpdatedAt: DateTime.now(),
      changeRulesUpdatedAt: DateTime.now(),
    );
  }

  String courseNamesOf(SchedulePageController controller) =>
      controller.courses.map((course) => course.courseName).join(',');

  SchedulePageController controllerWith(
    Future<ScheduleLoadResult> Function({
      ScheduleTermContext? termContext,
      String? studentId,
      bool forceRefresh,
    })
    loader, {
    bool loggedIn = true,
    String? studentId = ownerA,
  }) {
    final controller = SchedulePageController(
      loggedIn: loggedIn,
      studentId: studentId,
      loader: loader,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<ScheduleLoadResult> emptyResult({
    ScheduleTermContext? termContext,
    String? studentId,
    bool forceRefresh = false,
  }) async => const ScheduleLoadResult();

  test('propagates automaticLoginPaused from the load result', () async {
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async => const ScheduleLoadResult(
        requiresLogin: true,
        automaticLoginPaused: true,
      ),
    );

    expect(controller.automaticLoginPaused, isFalse);
    await controller.fetchSchedule();
    expect(controller.automaticLoginPaused, isTrue);
  });

  test('ordinary load result keeps the pause flag false', () async {
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async => const ScheduleLoadResult(message: 'ok'),
    );

    await controller.fetchSchedule();
    expect(controller.automaticLoginPaused, isFalse);
  });

  test('manual login success clears the pause flag', () async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async => const ScheduleLoadResult(
        requiresLogin: true,
        automaticLoginPaused: true,
      ),
    );

    await controller.fetchSchedule();
    expect(controller.automaticLoginPaused, isTrue);

    expect(controller.onLoginSuccess(studentId: ownerA), isTrue);
    expect(controller.automaticLoginPaused, isFalse);
    expect(controller.loggedIn, isTrue);
  });

  test('passes the verified owner to the loader', () async {
    String? requestedOwner;
    final controller = controllerWith(({
      ScheduleTermContext? termContext,
      String? studentId,
      bool forceRefresh = false,
    }) async {
      requestedOwner = studentId;
      return const ScheduleLoadResult();
    });

    await controller.fetchSchedule();

    expect(requestedOwner, ownerA);
  });

  test(
    'unauthenticated cold start hides the previous account cache from prefs',
    () async {
      final termContext = ScheduleTermContext.current();
      final cached = snapshotFor(
        ownerA,
        courseName: 'A班课表',
        termContext: termContext,
      );
      SharedPreferences.setMockInitialValues({
        cacheStorageKey: jsonEncode({
          '$ownerA|${termContext.academicYear}|${termContext.term}': cached
              .toJson(),
        }),
      });
      await ScheduleService.instance.restoreCache();
      ZhengfangAuth.instance.debugReset();

      final controller = controllerWith(
        emptyResult,
        loggedIn: false,
        studentId: null,
      );
      controller.restoreCachedSnapshot();

      expect(controller.loggedIn, isFalse);
      expect(controller.courses, isEmpty);
      expect(controller.courseChangeRules, isEmpty);
      expect(controller.scheduleUpdatedAt, isNull);

      // 同一份缓存只在身份可验证时才允许展示，证明上面的空态不是缓存缺失。
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      controller.updateLoggedIn(true, studentId: ownerA);
      expect(courseNamesOf(controller), 'A班课表');
    },
  );

  test('A to B switch clears A immediately and only restores B', () async {
    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    ScheduleService.instance.debugSetSnapshot(
      snapshotFor(ownerA, courseName: 'A班课表', termContext: termContext),
    );
    ScheduleService.instance.debugSetSnapshot(
      snapshotFor(ownerB, courseName: 'B班课表', termContext: termContext),
    );

    final controller = controllerWith(emptyResult);
    controller.restoreCachedSnapshot();
    expect(courseNamesOf(controller), 'A班课表');

    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerB);
    controller.updateLoggedIn(true, studentId: ownerB);

    expect(controller.loggedIn, isTrue);
    expect(courseNamesOf(controller), 'B班课表');
    expect(controller.scheduleUpdatedAt, isNotNull);
  });

  test('repeated notifications for the same identity keep the schedule', () {
    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    ScheduleService.instance.debugSetSnapshot(
      snapshotFor(ownerA, courseName: 'A班课表', termContext: termContext),
    );

    final controller = controllerWith(emptyResult);
    controller.restoreCachedSnapshot();
    expect(courseNamesOf(controller), 'A班课表');

    controller.updateLoggedIn(true, studentId: ownerA);

    expect(courseNamesOf(controller), 'A班课表');
  });

  test('logout clears the previous account schedule', () async {
    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    ScheduleService.instance.debugSetSnapshot(
      snapshotFor(ownerA, courseName: 'A班课表', termContext: termContext),
    );

    final controller = controllerWith(emptyResult);
    controller.restoreCachedSnapshot();
    expect(courseNamesOf(controller), 'A班课表');

    ZhengfangAuth.instance.debugSetSession(active: false);
    controller.updateLoggedIn(false);

    expect(controller.loggedIn, isFalse);
    expect(controller.courses, isEmpty);
    expect(controller.courseChangeRules, isEmpty);
    expect(controller.scheduleUpdatedAt, isNull);
    expect(
      ScheduleService.instance.preferredSnapshot(
        termContext: termContext,
        studentId: ownerA,
      ),
      isNull,
    );
  });

  test(
    'a late result for the previous account never restores after A to B',
    () async {
      final termContext = ScheduleTermContext.current();
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      ScheduleService.instance.debugSetSnapshot(
        snapshotFor(ownerB, courseName: 'B班课表', termContext: termContext),
      );

      final completer = Completer<ScheduleLoadResult>();
      String? requestedOwner;
      final controller = controllerWith(({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) {
        requestedOwner = studentId;
        return completer.future;
      });

      final pending = controller.fetchSchedule();
      expect(requestedOwner, ownerA);
      expect(controller.loading, isTrue);

      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerB);
      controller.updateLoggedIn(true, studentId: ownerB);
      expect(courseNamesOf(controller), 'B班课表');
      expect(controller.loading, isFalse);

      completer.complete(
        ScheduleLoadResult(
          snapshot: snapshotFor(
            ownerA,
            courseName: 'A班课表',
            termContext: termContext,
          ),
        ),
      );
      await pending;

      expect(courseNamesOf(controller), 'B班课表');
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
    },
  );

  test('rejects a result whose snapshot belongs to another account', () async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);

    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async => ScheduleLoadResult(
        snapshot: snapshotFor(
          ownerB,
          courseName: 'B班课表',
          termContext: termContext ?? ScheduleTermContext.current(),
        ),
      ),
    );

    await controller.fetchSchedule();

    expect(controller.courses, isEmpty);
    expect(controller.loading, isFalse);
  });

  test('accepts a same-owner result re-queried under the new revision after silent re-login', () async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);

    late final SchedulePageController controller;
    controller = controllerWith(({
      ScheduleTermContext? termContext,
      String? studentId,
      bool forceRefresh = false,
    }) async {
      // 模拟 guard 的静默自动登录：同一账号会话 revision 变化后，服务在新
      // revision 下重新查询并返回该账号自己的结果；页面同时收到同身份通知
      //（身份 no-op，但会话归属已刷新）。控制器必须照常接纳课程结果。
      final revisionBefore = ZhengfangAuth.instance.sessionRevision;
      ZhengfangAuth.instance.debugSetSession(active: false);
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      controller.updateLoggedIn(true, studentId: ownerA);
      expect(
        ZhengfangAuth.instance.sessionRevision,
        greaterThan(revisionBefore),
      );
      return ScheduleLoadResult(
        snapshot: snapshotFor(
          ownerA,
          courseName: 'A班课表',
          termContext: termContext ?? ScheduleTermContext.current(),
        ),
      );
    });

    await controller.fetchSchedule();

    expect(courseNamesOf(controller), 'A班课表');
    expect(controller.error, isNull);
  });

  test('manual login adopts the verified account cache', () async {
    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    ScheduleService.instance.debugSetSnapshot(
      snapshotFor(ownerA, courseName: 'A班课表', termContext: termContext),
    );

    final controller = controllerWith(
      emptyResult,
      loggedIn: false,
      studentId: null,
    );
    expect(controller.courses, isEmpty);

    expect(controller.onLoginSuccess(studentId: ownerA), isTrue);

    expect(controller.loggedIn, isTrue);
    expect(courseNamesOf(controller), 'A班课表');
  });

  test(
    'manual login without a verified identity clears the previous account',
    () async {
      final termContext = ScheduleTermContext.current();
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      ScheduleService.instance.debugSetSnapshot(
        snapshotFor(ownerA, courseName: 'A班课表', termContext: termContext),
      );

      var loaderCalls = 0;
      String? requestedOwner = 'unset';
      final controller = controllerWith(({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async {
        loaderCalls++;
        requestedOwner = studentId;
        return const ScheduleLoadResult();
      });
      controller.restoreCachedSnapshot();
      expect(courseNamesOf(controller), 'A班课表');

      // auth 会话仍停在 A，但登录回调没有可信学号：不得复用上一 owner。
      expect(controller.onLoginSuccess(), isFalse);
      expect(loaderCalls, 0);

      expect(controller.loggedIn, isFalse);
      expect(controller.courses, isEmpty);
      expect(controller.courseChangeRules, isEmpty);
      expect(controller.scheduleUpdatedAt, isNull);
      expect(controller.error, isNull);
      expect(controller.infoMessage, isNull);

      // 即使随后刷新，也只能以「无身份」发出，绝不带旧 owner。
      await controller.fetchSchedule();
      expect(requestedOwner, isNull);
    },
  );

  test(
    'manual login rejects an identity that differs from the auth session',
    () async {
      final termContext = ScheduleTermContext.current();
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      ScheduleService.instance.debugSetSnapshot(
        snapshotFor(ownerA, courseName: 'A班课表', termContext: termContext),
      );
      ScheduleService.instance.debugSetSnapshot(
        snapshotFor(ownerB, courseName: 'B班课表', termContext: termContext),
      );

      final controller = controllerWith(emptyResult);
      controller.restoreCachedSnapshot();
      expect(courseNamesOf(controller), 'A班课表');

      // 当前教务会话是 A，回调却声称 B：不采纳、清空旧 owner、也不恢复 B 缓存。
      expect(controller.onLoginSuccess(studentId: ownerB), isFalse);
      expect(controller.loggedIn, isFalse);
      expect(controller.courses, isEmpty);

      // 身份补齐后同一入口仍能正常登录。
      expect(controller.onLoginSuccess(studentId: ownerA), isTrue);
      expect(controller.loggedIn, isTrue);
      expect(courseNamesOf(controller), 'A班课表');
    },
  );

  test('switching terms restores the selected term cache', () async {
    final current = ScheduleTermContext.current();
    final other = current.copyWith(term: current.term == 3 ? 12 : 3);
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    ScheduleService.instance.debugSetSnapshot(
      snapshotFor(ownerA, courseName: '本学期课表', termContext: current),
    );
    ScheduleService.instance.debugSetSnapshot(
      snapshotFor(ownerA, courseName: '另一学期课表', termContext: other),
    );

    final controller = controllerWith(emptyResult);
    controller.restoreCachedSnapshot();
    expect(courseNamesOf(controller), '本学期课表');

    controller.switchTerm(other.term);

    expect(controller.term, other.term);
    expect(courseNamesOf(controller), '另一学期课表');
  });

  test(
    'a stale result from the previous term is discarded after a manual switch',
    () async {
      final current = ScheduleTermContext.current();
      final other = current.copyWith(term: current.term == 3 ? 12 : 3);
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      ScheduleService.instance.debugSetSnapshot(
        snapshotFor(ownerA, courseName: '另一学期课表', termContext: other),
      );

      final completer = Completer<ScheduleLoadResult>();
      final controller = controllerWith(
        ({
          ScheduleTermContext? termContext,
          String? studentId,
          bool forceRefresh = false,
        }) => completer.future,
      );

      final pending = controller.fetchSchedule();
      expect(controller.loading, isTrue);

      controller.switchTerm(other.term);
      expect(controller.term, other.term);
      expect(courseNamesOf(controller), '另一学期课表');
      expect(controller.loading, isFalse);

      // 旧学期请求此刻才返回：课程 / 提示 / 错误都不得写回。
      completer.complete(
        ScheduleLoadResult(
          snapshot: snapshotFor(
            ownerA,
            courseName: '本学期课表',
            termContext: current,
          ),
          message: '旧学期刷新完成',
        ),
      );
      await pending;

      expect(courseNamesOf(controller), '另一学期课表');
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
      expect(controller.infoMessage, isNull);
    },
  );

  test('a stale result does not end the new term loading state', () async {
    final current = ScheduleTermContext.current();
    final other = current.copyWith(term: current.term == 3 ? 12 : 3);
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);

    final first = Completer<ScheduleLoadResult>();
    final second = Completer<ScheduleLoadResult>();
    final requestedTerms = <int?>[];
    final controller = controllerWith(({
      ScheduleTermContext? termContext,
      String? studentId,
      bool forceRefresh = false,
    }) {
      requestedTerms.add(termContext?.term);
      return requestedTerms.length == 1 ? first.future : second.future;
    });

    final pendingFirst = controller.fetchSchedule();
    expect(requestedTerms, [null]);
    expect(controller.loading, isTrue);

    // 新学期没有缓存 → switchTerm 立即发起新学期 fetch。
    controller.switchTerm(other.term);
    expect(requestedTerms, [null, other.term]);
    expect(controller.loading, isTrue);

    // 旧学期请求先返回：不得结束新学期的 loading，也不得写入课程 / 错误 / 提示。
    first.complete(
      ScheduleLoadResult(
        snapshot: snapshotFor(
          ownerA,
          courseName: '本学期课表',
          termContext: current,
        ),
        message: '旧学期结果',
      ),
    );
    await pendingFirst;
    expect(controller.loading, isTrue);
    expect(controller.courses, isEmpty);
    expect(controller.error, isNull);
    expect(controller.infoMessage, isNull);

    // 新学期自己的结果仍能正常展示并结束 loading。
    second.complete(
      ScheduleLoadResult(
        snapshot: snapshotFor(ownerA, courseName: '另一学期课表', termContext: other),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.loading, isFalse);
    expect(courseNamesOf(controller), '另一学期课表');
    expect(controller.error, isNull);
  });

  test('a late pause from the previous account never pauses the current logout guidance', () async {
    final completer = Completer<ScheduleLoadResult>();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) => completer.future,
    );

    // A 的请求在途。
    final pending = controller.fetchSchedule();
    expect(controller.loggedIn, isTrue);

    // A→B 切换，B 登录后又登出。
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerB);
    controller.updateLoggedIn(true, studentId: ownerB);
    ZhengfangAuth.instance.debugSetSession(active: false);
    controller.updateLoggedIn(false);
    expect(controller.loggedIn, isFalse);
    expect(controller.automaticLoginPaused, isFalse);

    // A 的迟到结果声称自动登录已暂停：不得污染 B 登出后的未登录引导。
    completer.complete(
      const ScheduleLoadResult(
        requiresLogin: true,
        automaticLoginPaused: true,
        message: '教务登录已过期，请重新登录',
      ),
    );
    await pending;

    expect(controller.loggedIn, isFalse);
    expect(controller.automaticLoginPaused, isFalse);
    expect(controller.error, isNull);
    expect(controller.infoMessage, isNull);
  });

  test('the expired account keeps its own paused logout guidance', () async {
    final completer = Completer<ScheduleLoadResult>();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) => completer.future,
    );

    final pending = controller.fetchSchedule();
    expect(controller.loggedIn, isTrue);

    // 同一账号在请求期间因认证过期被登出（auth 通知先于结果返回）。
    ZhengfangAuth.instance.debugSetSession(active: false);
    controller.updateLoggedIn(false);
    // 重复的登出通知是 no-op，不能因此丢掉当前引导的会话归属。
    controller.updateLoggedIn(false);
    expect(controller.loggedIn, isFalse);
    expect(controller.automaticLoginPaused, isFalse);

    completer.complete(
      const ScheduleLoadResult(
        requiresLogin: true,
        automaticLoginPaused: true,
        message: '教务登录已过期，请重新登录',
      ),
    );
    await pending;

    expect(controller.loggedIn, isFalse);
    expect(controller.automaticLoginPaused, isTrue);
  });

  test(
    'a current logged-out request still surfaces its paused guidance',
    () async {
      ZhengfangAuth.instance.debugSetSession(active: false);
      final controller = controllerWith(
        ({
          ScheduleTermContext? termContext,
          String? studentId,
          bool forceRefresh = false,
        }) async => const ScheduleLoadResult(
          requiresLogin: true,
          automaticLoginPaused: true,
        ),
        loggedIn: false,
        studentId: null,
      );

      await controller.fetchSchedule();

      expect(controller.loggedIn, isFalse);
      expect(controller.automaticLoginPaused, isTrue);
    },
  );

  test('a pause from before a same-owner re-login never pauses the new logout guidance', () async {
    final completer = Completer<ScheduleLoadResult>();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) => completer.future,
    );

    // 旧 A 会话的请求在途。
    final pending = controller.fetchSchedule();
    expect(controller.loggedIn, isTrue);

    // 同账号成功重登：auth sessionRevision 前进、owner 不变；页面收到通知。
    ZhengfangAuth.instance.debugSetSession(active: false);
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
    controller.updateLoggedIn(true, studentId: ownerA);
    expect(controller.loggedIn, isTrue);

    // 新 A 会话随后登出。
    ZhengfangAuth.instance.debugSetSession(active: false);
    controller.updateLoggedIn(false);
    expect(controller.loggedIn, isFalse);
    expect(controller.automaticLoginPaused, isFalse);

    // 旧 A 会话的迟到暂停：不得冒充新 A 会话登出后的引导。
    completer.complete(
      const ScheduleLoadResult(
        requiresLogin: true,
        automaticLoginPaused: true,
        message: '教务登录已过期，请重新登录',
      ),
    );
    await pending;

    expect(controller.loggedIn, isFalse);
    expect(controller.automaticLoginPaused, isFalse);
  });

  test(
    'a pause from the current session survives a same-owner re-login',
    () async {
      final completer = Completer<ScheduleLoadResult>();
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      final controller = controllerWith(
        ({
          ScheduleTermContext? termContext,
          String? studentId,
          bool forceRefresh = false,
        }) => completer.future,
      );

      // 同账号成功重登后再发起请求：该请求归属新会话。
      ZhengfangAuth.instance.debugSetSession(active: false);
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: ownerA);
      controller.updateLoggedIn(true, studentId: ownerA);

      final pending = controller.fetchSchedule();
      expect(controller.loggedIn, isTrue);

      ZhengfangAuth.instance.debugSetSession(active: false);
      controller.updateLoggedIn(false);
      expect(controller.automaticLoginPaused, isFalse);

      completer.complete(
        const ScheduleLoadResult(
          requiresLogin: true,
          automaticLoginPaused: true,
          message: '教务登录已过期，请重新登录',
        ),
      );
      await pending;

      expect(controller.loggedIn, isFalse);
      expect(controller.automaticLoginPaused, isTrue);
    },
  );
}
