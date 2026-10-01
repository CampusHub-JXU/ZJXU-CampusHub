import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/semester/current_term_resolver.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_page.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';

import '../../helpers/mock_http_client_adapter.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    final today = DateTime.now();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      today.year,
      today.month,
      today.day,
    );
  });

  ScheduleCacheSnapshot cachedSnapshotFor(
    String studentId,
    String courseName,
    ScheduleTermContext termContext,
  ) {
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

  testWidgets('shows course change reminders above the schedule grid', (
    tester,
  ) async {
    final now = DateTime.now();
    final termContext = ScheduleTermContext.current(now);

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      ScheduleCacheSnapshot(
        studentId: '2025000001',
        termContext: termContext,
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
        changeRules: [
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
            termContext: termContext,
          ),
        ],
        scheduleUpdatedAt: now,
        changeRulesUpdatedAt: now,
        changeRulesCurrentScoped: true,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byTooltip('调课提醒'), findsOneWidget);
    expect(find.text('已根据这些提醒自动修正课表显示'), findsNothing);

    // 页面在登录态下会保留一个后台刷新（顶部线性进度条持续动画），
    // 因此用固定时长 pump 完成弹层入场，而不是 pumpAndSettle。
    await tester.tap(find.byTooltip('调课提醒'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('调课提醒'), findsOneWidget);
    expect(find.text('AI+创新创业基础'), findsWidgets);
    // 调课为「原 / 改」对照，时段统一「周X a–b 节」。
    expect(find.textContaining('周四 8–9 节'), findsOneWidget);
    expect(find.textContaining('周五 8–9 节 · 铭德楼468'), findsOneWidget);
    expect(find.textContaining(' -> '), findsNothing);
    expect(find.text('胡亚楠'), findsWidgets);
  });

  testWidgets('switching accounts replaces the visible schedule immediately', (
    tester,
  ) async {
    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', 'A班专属课程', termContext),
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000002', 'B班专属课程', termContext),
    );

    await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
    await tester.pump();
    expect(find.text('A班专属课程'), findsWidgets);
    expect(find.text('B班专属课程'), findsNothing);

    // 切账号必须让页面收到身份通知（debugSetSession 只改状态不通知）。
    await ZhengfangAuth.instance.markLoggedOut();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000002',
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();

    expect(find.text('B班专属课程'), findsWidgets);
    expect(find.text('A班专属课程'), findsNothing);
  });

  testWidgets('switching terms from the menu shows the selected term cache', (
    tester,
  ) async {
    final current = ScheduleTermContext.current();
    final other = current.copyWith(term: current.term == 3 ? 12 : 3);
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', '本学期专属课程', current),
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', '另一学期专属课程', other),
    );

    await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
    await tester.pump();
    expect(find.text('本学期专属课程'), findsWidgets);

    await tester.tap(find.byTooltip('切换学期'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(other.term == 12 ? '第二学期' : '第一学期'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('另一学期专属课程'), findsWidgets);
    expect(find.text('本学期专属课程'), findsNothing);
  });

  Future<void> pumpLoginView(
    WidgetTester tester, {
    required bool automaticLoginPaused,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildScheduleLoginView(
            automaticLoginPaused: automaticLoginPaused,
            onAction: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('paused automatic login shows manual-login guidance', (
    tester,
  ) async {
    await pumpLoginView(tester, automaticLoginPaused: true);

    expect(find.text('需要手动登录'), findsOneWidget);
    expect(find.textContaining('自动登录已暂停'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('登录后查看课表'), findsNothing);
  });

  testWidgets('not paused keeps the original login guidance', (tester) async {
    await pumpLoginView(tester, automaticLoginPaused: false);

    expect(find.text('登录后查看课表'), findsOneWidget);
    expect(find.textContaining('课表刷新依赖教务系统会话'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('需要手动登录'), findsNothing);
  });

  testWidgets('schedule grid fits 360px screen at 1.5x text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', '大字号下的课程名称', termContext),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: const SchedulePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('大字号下的课程名称'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a course cell opens the detail sheet', (tester) async {
    final termContext = ScheduleTermContext.current();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    ScheduleService.instance.debugSetSnapshot(
      cachedSnapshotFor('2025000001', '点选课程详情', termContext),
    );

    await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('点选课程详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('教师：'), findsOneWidget);
    expect(find.textContaining('教室：101'), findsOneWidget);
    expect(find.textContaining('节次：第 1 - 2 节'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'course cell exposes a semantics tap action that opens the sheet',
    (tester) async {
      final handle = tester.ensureSemantics();
      final termContext = ScheduleTermContext.current();
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '2025000001',
      );
      ScheduleService.instance.debugSetSnapshot(
        cachedSnapshotFor('2025000001', '语义点选课程详情', termContext),
      );

      await tester.pumpWidget(const MaterialApp(home: SchedulePage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final cellNode = find.semantics.byLabel('语义点选课程详情，101');
      expect(cellNode.evaluate(), hasLength(1));
      expect(
        cellNode.evaluate().single.getSemanticsData().hasAction(
          SemanticsAction.tap,
        ),
        isTrue,
      );

      // 语义 tap 必须与真实点击等价，打开同一个课程详情弹层。
      tester.semantics.tap(cellNode);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('教师：'), findsOneWidget);
      expect(find.textContaining('教室：101'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    },
  );

  /// 未登录刷新与登录引导必须共用同一个教务登录弹层：用 GoRouter 注册同名
  /// 整页登录探针路由，一旦页面重新 push `academic-system-login` 探针页就会出现。
  ///
  /// 未登录时页内可点的刷新入口只有登录引导按钮（AppBar 刷新 / 错误重试只在
  /// controller 仍持有课表时渲染），它与 `_refreshScheduleOrLogin` 的未登录
  /// 分支调用同一个 `_presentLoginPrompt(force: true)`，因此这条点击路径同样
  /// 覆盖「未登录刷新不得跳整页登录」的约束。
  Future<void> pumpPageWithLoginRouteProbe(
    WidgetTester tester, {
    required void Function() onLoginRoutePushed,
  }) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const SchedulePage()),
        GoRoute(
          path: '/academic-system-login',
          name: 'academic-system-login',
          builder: (context, state) {
            onLoginRoutePushed();
            return const Scaffold(body: Center(child: Text('整页登录路由')));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 弹层表单较高：放大视口，保证「关闭」按钮与页内登录按钮都可见可点。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 所有请求立即失败的 Dio 适配器：用于证明页面是否真的发起了刷新请求，
  /// 同时不触真实网络（请求失败由服务层按既有离线链路处理）。
  Future<MockHttpClientAdapter> installOfflineRequestAdapter() async {
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'jxuc_schedule_page_test/$folderName/';
    await DioClient.instance.ensureInitialized();
    final adapter = MockHttpClientAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
    return adapter;
  }

  Future<void> dismissLoginModal(WidgetTester tester) async {
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('关闭'), findsNothing);
  }

  testWidgets(
    'logged-out schedule entry opens the login modal instead of the login route',
    (tester) async {
      useTallViewport(tester);
      var loginRoutePushes = 0;
      await pumpPageWithLoginRouteProbe(
        tester,
        onLoginRoutePushed: () => loginRoutePushes++,
      );

      expect(find.byTooltip('关闭'), findsOneWidget);
      expect(find.text('教务系统'), findsOneWidget);
      expect(find.text('登录后查看课表'), findsOneWidget);
      expect(find.text('整页登录路由'), findsNothing);
      expect(loginRoutePushes, 0);

      await dismissLoginModal(tester);

      // 关闭弹层后停留在页内登录引导，没有被整页登录路由替换。
      expect(find.text('登录后查看课表'), findsOneWidget);
      expect(find.text('整页登录路由'), findsNothing);
      expect(loginRoutePushes, 0);
    },
  );

  testWidgets(
    'dismissed login modal is reopened by the login action exactly once',
    (tester) async {
      useTallViewport(tester);
      var loginRoutePushes = 0;
      await pumpPageWithLoginRouteProbe(
        tester,
        onLoginRoutePushed: () => loginRoutePushes++,
      );
      await dismissLoginModal(tester);

      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byTooltip('关闭'), findsOneWidget);
      expect(find.text('教务系统'), findsOneWidget);
      expect(find.text('整页登录路由'), findsNothing);
      expect(loginRoutePushes, 0);
    },
  );

  testWidgets('repeat login taps keep exactly one login modal', (tester) async {
    useTallViewport(tester);
    var loginRoutePushes = 0;
    await pumpPageWithLoginRouteProbe(
      tester,
      onLoginRoutePushed: () => loginRoutePushes++,
    );
    await dismissLoginModal(tester);

    // 同一帧内连续触发两次：在途守卫必须让第二次调用 no-op，不叠加弹层。
    final loginButton = find.widgetWithText(FilledButton, '登录教务系统');
    await tester.tap(loginButton, warnIfMissed: false);
    await tester.tap(loginButton, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.text('整页登录路由'), findsNothing);
    expect(loginRoutePushes, 0);
  });

  testWidgets(
    'verified login from the prompt refreshes the schedule only after the identity check',
    (tester) async {
      useTallViewport(tester);
      await CurrentTermResolver.instance.debugReset();
      final adapter = await installOfflineRequestAdapter();
      ScheduleService.instance.debugSetSnapshot(
        cachedSnapshotFor(
          '2025000001',
          '登录后刷新课程',
          ScheduleTermContext.current(),
        ),
      );

      var allowLogin = false;
      Future<bool> presenter(BuildContext context) async {
        if (!allowLogin) return false;
        ZhengfangAuth.instance.debugSetSession(
          active: true,
          studentId: '2025000001',
        );
        return true;
      }

      await tester.pumpWidget(
        MaterialApp(home: SchedulePage(loginPromptPresenter: presenter)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 入口弹层未被采纳：仍在登录引导页，且零请求。
      expect(find.text('登录后查看课表'), findsOneWidget);
      expect(adapter.requestLog, isEmpty);

      allowLogin = true;
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 身份已验证：采纳该 owner 的缓存并强制刷新（离线失败走缓存展示）。
      expect(find.text('登录后查看课表'), findsNothing);
      expect(find.text('登录后刷新课程'), findsWidgets);
      expect(find.textContaining('课表刷新失败'), findsOneWidget);
      expect(
        adapter.requestLog.where((entry) => entry.contains('xskbcx_cxXsKb')),
        isNotEmpty,
        reason: '身份验证通过后必须发起主课表刷新',
      );
    },
  );

  testWidgets(
    'login success without a verified identity neither refreshes nor shows any schedule',
    (tester) async {
      useTallViewport(tester);
      final adapter = await installOfflineRequestAdapter();
      ScheduleService.instance.debugSetSnapshot(
        cachedSnapshotFor(
          '2025000001',
          '不该被采纳的课程',
          ScheduleTermContext.current(),
        ),
      );

      var allowLogin = false;
      Future<bool> presenter(BuildContext context) async {
        if (!allowLogin) return false;
        // 弹层报告成功，但教务身份尚未就绪。
        return true;
      }

      await tester.pumpWidget(
        MaterialApp(home: SchedulePage(loginPromptPresenter: presenter)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      allowLogin = true;
      await tester.tap(find.widgetWithText(FilledButton, '登录教务系统'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('登录后查看课表'), findsOneWidget);
      expect(find.text('不该被采纳的课程'), findsNothing);
      expect(adapter.requestLog, isEmpty, reason: '身份不可验证时必须零请求');
    },
  );
}
