import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/home/home_page.dart';
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
    FeatureEntryCatalog.instance.debugSetEntries([
      _entry(
        id: 'second-classroom',
        title: '第二课堂',
        subtitle: '学分活动',
        icon: Icons.workspace_premium_outlined,
        accentColor: const Color(0xFFD4AF37),
        sortOrder: 20,
      ),
      _entry(
        id: 'library',
        title: '图书馆',
        subtitle: '馆藏检索',
        icon: Icons.local_library_outlined,
        accentColor: const Color(0xFF1565C0),
        sortOrder: 30,
      ),
      _entry(
        id: 'changxing-jiada',
        title: '畅行嘉大',
        subtitle: '请假与返校',
        icon: Icons.north_rounded,
        accentColor: const Color(0xFF2EA567),
        sortOrder: 40,
      ),
      _entry(
        id: 'sjjx-notice-list',
        title: '实践通知',
        subtitle: '实践教学通知',
        icon: Icons.science_outlined,
        accentColor: const Color(0xFF1976D2),
        sortOrder: 50,
      ),
    ]);
    CampusCardService.instance.debugSetCachedBalance(null);
    DormElectricityService.instance.debugReset();
    ExamService.instance.debugReset();
    GradesService.instance.debugReset();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      now.year,
      now.month,
      now.day,
    );
    await ScheduleService.instance.debugClearCache();
  });

  tearDown(() {
    FeatureEntryCatalog.instance.debugReset();
  });

  /// SliverList 懒构建：视口以下的分区不会挂载。
  /// 需要断言整页信息架构的用例放大测试视口，保证全部分区构建。
  void useLargeSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('renders startup placeholders before bootstrap completes', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    expect(find.text('登录后查看课程'), findsOneWidget);
    // 校园卡与宿舍电费均为未获取状态，状态条显示占位符。
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
    useLargeSurface(tester);
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

    // Hero 保留给课表状态，低电量升级为事件横幅；状态条数值同步告警。
    expect(find.text('今天没课'), findsOneWidget);
    expect(find.textContaining('电量偏低'), findsOneWidget);
    expect(find.text('3.20 度'), findsOneWidget);
  });

  testWidgets('exam within 24h takes hero when no course remains today', (
    tester,
  ) async {
    useLargeSurface(tester);
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

  testWidgets('renders sections and quick actions without fixed-height cards', (
    tester,
  ) async {
    useLargeSurface(tester);
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    expect(find.text('常用'), findsOneWidget);
    expect(find.text('全部校园服务'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('本周'), findsOneWidget);
    // 付款码同时出现在状态条与常用入口。
    expect(find.text('付款码'), findsNWidgets(2));
    // 功能目录中的首页学习入口保留。
    expect(find.text('图书馆'), findsOneWidget);
    expect(find.text('第二课堂'), findsOneWidget);
  });

  testWidgets('hero tap navigates to schedule', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const HomePage(),
        ),
        GoRoute(
          path: '/schedule',
          name: 'schedule',
          builder: (context, state) => const Scaffold(body: Text('课表页面')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('查看课表'));
    await tester.pumpAndSettle();

    expect(find.text('课表页面'), findsOneWidget);
  });

  testWidgets('library tile navigates to dedicated library entry', (
    tester,
  ) async {
    useLargeSurface(tester);
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

  testWidgets('second classroom tile navigates to dedicated entry', (
    tester,
  ) async {
    useLargeSurface(tester);
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

FeatureEntryDefinition _entry({
  required String id,
  required String title,
  required String subtitle,
  required IconData icon,
  required Color accentColor,
  required int sortOrder,
}) {
  return FeatureEntryDefinition(
    id: id,
    title: title,
    subtitle: subtitle,
    icon: icon,
    accentColor: accentColor,
    routeName: id,
    spans: const FeatureEntryResponsiveSpan(
      compact: FeatureEntrySpan(columns: 1, rows: 1),
      expanded: FeatureEntrySpan(columns: 1, rows: 1),
    ),
    placements: const {FeatureEntryPlacement.homeLearning},
    sortOrder: sortOrder,
  );
}
