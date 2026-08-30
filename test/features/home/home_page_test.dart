import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/home/home_page.dart';
import 'package:jxu_campus_hub/features/home/home_zone_controller.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_event_banner.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({});
    AppBootstrapController.instance.debugReset();
    CampusCardService.instance.debugSetCachedBalance(null);
    DormElectricityService.instance.debugReset();
    ExamService.instance.debugReset();
    GradesService.instance.debugReset();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      now.year,
      now.month,
      now.day,
    );
    HomeZoneController.instance.updateZone(0);
    await ScheduleService.instance.debugClearCache();
  });

  tearDown(() {
    // 单例注入点在页面 dispose 时置空；这里兜底防止失败用例泄漏。
    HomeZoneController.instance
      ..scrollToTop = null
      ..scrollToFunction = null;
  });

  /// 手机尺寸视口：ScrollSpy 判定依赖真实的首屏/视口比例。
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('renders startup placeholders before bootstrap completes', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    expect(find.text('登录后查看课程'), findsOneWidget);
    // 校园卡与宿舍电费均为未获取状态，资产行显示占位符。
    expect(find.text('--'), findsNWidgets(2));
  });

  testWidgets('does not prompt unified auth login after bootstrap', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('登录一卡通'), findsNothing);
  });

  testWidgets('hydrates cached data after bootstrap local state is ready', (
    tester,
  ) async {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));
    const studentId = '2025000001';
    final termContext = ScheduleTermContext.current(now);

    SharedPreferences.setMockInitialValues({
      'dorm_community_id': 'community',
      'dorm_building_id': 'building',
      'dorm_floor_id': 'floor',
      'dorm_room_id': 'room',
    });

    CampusCardService.instance.debugSetCachedBalance(23.5, updatedAt: now);
    // 把开学日固定为今天，避免假期窗口运行时"明天"落在第 1 周之前。
    await SemesterCalendar.instance.setSemesterStartDate(now);
    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: now,
    );
    ScheduleService.instance.debugSetSnapshot(
      ScheduleCacheSnapshot(
        studentId: studentId,
        termContext: termContext,
        courses: [
          CourseEntry(
            courseName: '线性代数',
            teacherName: '张老师',
            weekday: tomorrow.weekday,
            startLesson: 1,
            endLesson: 1,
            // 覆盖第 1-2 周，保证"明天"无论落在哪一周都在范围内。
            weekRange: '1-2周',
            classroom: 'A101',
            campus: '梁林校区',
            typeSymbol: '',
          ),
        ],
        scheduleUpdatedAt: now,
        changeRulesUpdatedAt: now,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('¥23.5'), findsOneWidget);
    expect(find.text('42 度'), findsOneWidget);
    // 今天无课：Hero 展示"今天没课 + 明天第一节课预告"。
    expect(find.text('今天没课'), findsOneWidget);
    expect(find.text('下一节：明天 08:00'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget);
  });

  testWidgets('low electricity triggers event banner while hero shows course', (
    tester,
  ) async {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));

    DormElectricityService.instance.debugSetCachedElectricity(
      3.2,
      updatedAt: now,
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);
    ScheduleService.instance.debugSetSnapshot(
      ScheduleCacheSnapshot(
        studentId: '2025000001',
        termContext: ScheduleTermContext.current(now),
        courses: [
          CourseEntry(
            courseName: '线性代数',
            teacherName: '张老师',
            weekday: tomorrow.weekday,
            startLesson: 1,
            endLesson: 1,
            weekRange: '1-2周',
            classroom: 'A101',
            campus: '梁林校区',
            typeSymbol: '',
          ),
        ],
        scheduleUpdatedAt: now,
        changeRulesUpdatedAt: now,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    // Hero 保留给课表状态，低电量升级为事件横幅；资产行数值同步告警。
    expect(find.text('今天没课'), findsOneWidget);
    expect(find.textContaining('电量偏低'), findsOneWidget);
    expect(find.text('3.20 度'), findsOneWidget);
  });

  testWidgets('exam within 24h takes hero when no course remains today', (
    tester,
  ) async {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));
    final tomorrowDate = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    final dateText =
        '${tomorrowDate.year}-'
        '${tomorrowDate.month.toString().padLeft(2, '0')}-'
        '${tomorrowDate.day.toString().padLeft(2, '0')}';

    SharedPreferences.setMockInitialValues({
      'exam_cached_data': jsonEncode([
        {
          'kcmc': '微观经济学',
          'kssj': '($dateText) 09:00-11:00',
          'cdmc': '1教302',
          'cdxqmc': '梁林校区',
          'zwh': '12',
          'ksmc': '期末考试',
          'kkxy': '经济学院',
          'cxbj': '',
          'xnmc': '2026-2027',
          'xqmmc': '1',
        },
      ]),
    });
    await ExamService.instance.restoreCache();
    await SemesterCalendar.instance.setSemesterStartDate(now);
    ScheduleService.instance.debugSetSnapshot(
      ScheduleCacheSnapshot(
        studentId: '2025000001',
        termContext: ScheduleTermContext.current(now),
        courses: [
          CourseEntry(
            courseName: '线性代数',
            teacherName: '张老师',
            weekday: tomorrow.weekday,
            startLesson: 1,
            endLesson: 1,
            weekRange: '1-2周',
            classroom: 'A101',
            campus: '梁林校区',
            typeSymbol: '',
          ),
        ],
        scheduleUpdatedAt: now,
        changeRulesUpdatedAt: now,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    // 24 小时内考试优先于「今天没课」，且不重复出现事件横幅。
    expect(find.text('明天考试'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('微观经济学'), findsOneWidget);
    expect(find.text('明天 09:00 微观经济学考试'), findsNothing);
  });

  testWidgets('event banner renders alert message and handles tap', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HomeEventBanner(
              alert: const HomeAlertPresentation(
                kind: HomeAlertKind.lowBalance,
                message: '校园卡余额 ¥5，余额偏低，建议尽快充值',
                routeName: 'campus-card',
              ),
              onTap: () => tapped++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('校园卡余额 ¥5，余额偏低，建议尽快充值'), findsOneWidget);
    await tester.tap(find.text('校园卡余额 ¥5，余额偏低，建议尽快充值'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('renders first screen without legacy sections and bento below', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    // 旧版首页区块已删除。
    expect(find.text('本周'), findsNothing);
    expect(find.text('常用'), findsNothing);
    expect(find.text('全部校园服务'), findsNothing);
    // 第一屏资产行 + 底部功能区 Bento 段落
    // （「宿舍电费」同时出现在资产行 label 与 Bento 瓦片标题）。
    expect(find.text('校园卡'), findsOneWidget);
    expect(find.text('宿舍电费'), findsNWidgets(2));
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('长按置顶'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('付款码'), findsOneWidget);
    expect(find.text('图书馆'), findsOneWidget);
    expect(find.text('第二课堂'), findsOneWidget);
  });

  testWidgets('dock zone controller scrolls to function anchor', (
    tester,
  ) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    expect(HomeZoneController.instance.zoneIndex, 0);
    expect(_scrollOffset(tester), 0);

    // 滚动动画的 Future 需要 pump 推进时钟才能完成，测试里不能直接
    // await（会死锁），fire-and-forget 后用 pumpAndSettle 等待落地。
    unawaited(HomeZoneController.instance.requestFunction());
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), greaterThan(0));

    unawaited(HomeZoneController.instance.requestHome());
    await tester.pumpAndSettle();

    expect(_scrollOffset(tester), 0);
  });

  testWidgets('scroll spy highlights function zone while scrolled down', (
    tester,
  ) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(HomeZoneController.instance.zoneIndex, 0);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(HomeZoneController.instance.zoneIndex, 1);

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(HomeZoneController.instance.zoneIndex, 0);
  });

  testWidgets('exam bento tile navigates to dedicated exam entry', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const HomePage(),
        ),
        GoRoute(
          path: '/exam',
          name: 'exam',
          builder: (context, state) => const Scaffold(body: Text('考试安排页面')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('考试安排'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('考试安排'));
    await tester.pumpAndSettle();

    expect(find.text('考试安排页面'), findsOneWidget);
  });

  testWidgets('library bento tile navigates to dedicated library entry', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const HomePage(),
        ),
        GoRoute(
          path: '/library',
          name: 'library',
          builder: (context, state) => const Scaffold(body: Text('图书馆页面')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('图书馆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图书馆'));
    await tester.pumpAndSettle();

    expect(find.text('图书馆页面'), findsOneWidget);
  });

  testWidgets('second classroom bento tile navigates to dedicated entry', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const HomePage(),
        ),
        GoRoute(
          path: '/second-classroom',
          name: 'second-classroom',
          builder: (context, state) => const Scaffold(body: Text('第二课堂页面')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(find.text('第二课堂'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二课堂'));
    await tester.pumpAndSettle();

    expect(find.text('第二课堂页面'), findsOneWidget);
  });
}

double _scrollOffset(WidgetTester tester) {
  final scrollable = tester.state<ScrollableState>(
    find.byType(Scrollable).first,
  );
  return scrollable.position.pixels;
}
