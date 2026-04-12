import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jiaxing_university_portal/app/app_bootstrap_controller.dart';
import 'package:jiaxing_university_portal/core/config/feature_entry_catalog.dart';
import 'package:jiaxing_university_portal/core/semester/semester_calendar.dart';
import 'package:jiaxing_university_portal/features/campus_card/campus_card_service.dart';
import 'package:jiaxing_university_portal/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jiaxing_university_portal/features/home/home_page.dart';
import 'package:jiaxing_university_portal/features/schedule/schedule_cache_snapshot.dart';
import 'package:jiaxing_university_portal/features/schedule/schedule_model.dart';
import 'package:jiaxing_university_portal/features/schedule/schedule_service.dart';
import 'package:jiaxing_university_portal/features/schedule/schedule_term_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({});
    AppBootstrapController.instance.debugReset();
    FeatureEntryCatalog.instance.debugSetEntries(
      FeatureEntryCatalog.instance.parse('''
entries:
  - id: second-classroom
    title: 第二课堂
    subtitle: 学分活动
    icon: workspace_premium_outlined
    color: gold
    route: second-classroom
    cardType: wide_rect
    span:
      columns: 2
      rows: 1
    placements:
      - home_learning
    sort: 20
  - id: library
    title: 图书馆
    subtitle: 馆藏检索
    icon: local_library_outlined
    color: info
    route: library
    cardType: wide_rect
    span:
      columns: 2
      rows: 1
    placements:
      - home_learning
    sort: 30
  - id: changxing-jiada
    title: 畅行嘉大
    subtitle: 请假与返校
    icon: north_rounded
    color: "#2EA567"
    route: changxing-jiada
    cardType: tall_rect
    span:
      columns: 1
      rows: 2
    placements:
      - home_learning
    sort: 40
  - id: sjjx-notice-list
    title: 实践通知
    subtitle: 实践教学通知
    icon: science_outlined
    color: "#1976D2"
    route: sjjx-notice-list
    cardType: small_square
    span:
      columns: 1
      rows: 1
    placements:
      - home_learning
    sort: 50
'''),
    );
    CampusCardService.instance.debugSetCachedBalance(null);
    DormElectricityService.instance.debugSetCachedElectricity(null);
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      now.year,
      now.month,
      now.day,
    );
    await ScheduleService.instance.debugClearCache();
  });

  testWidgets('renders startup placeholders before bootstrap completes', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    expect(find.text('未更新'), findsOneWidget);
    expect(find.text('登录后查看课程'), findsOneWidget);
    expect(find.text('余额未刷新，请先登录一卡通'), findsOneWidget);
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
            weekRange: '1周',
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

    expect(find.text('23.5'), findsOneWidget);
    expect(find.text('剩余 42 度'), findsOneWidget);
    expect(find.textContaining('课表更新于'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget);
    expect(find.text('明天 08:00-08:40'), findsOneWidget);
  });

  testWidgets('payment code label uses scale down layout', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    expect(find.text('付款码'), findsOneWidget);
    final fittedBox = tester.widget<FittedBox>(
      find
          .ancestor(of: find.text('付款码'), matching: find.byType(FittedBox))
          .first,
    );
    expect(fittedBox.fit, BoxFit.scaleDown);
  });

  testWidgets('library tile navigates to dedicated library entry', (
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

  testWidgets('second classroom tile navigates to dedicated entry', (
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
