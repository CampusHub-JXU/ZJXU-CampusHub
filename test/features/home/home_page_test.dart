import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/home/home_page.dart';
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
        spans: const FeatureEntryResponsiveSpan(
          compact: FeatureEntrySpan(columns: 2, rows: 1),
          expanded: FeatureEntrySpan(columns: 2, rows: 1),
        ),
      ),
      _entry(
        id: 'library',
        title: '图书馆',
        subtitle: '馆藏检索',
        icon: Icons.local_library_outlined,
        accentColor: const Color(0xFF1565C0),
        sortOrder: 30,
        spans: const FeatureEntryResponsiveSpan(
          compact: FeatureEntrySpan(columns: 2, rows: 1),
          expanded: FeatureEntrySpan(columns: 2, rows: 1),
        ),
      ),
      _entry(
        id: 'changxing-jiada',
        title: '畅行嘉大',
        subtitle: '请假与返校',
        icon: Icons.north_rounded,
        accentColor: const Color(0xFF2EA567),
        sortOrder: 40,
        spans: const FeatureEntryResponsiveSpan(
          compact: FeatureEntrySpan(columns: 1, rows: 2),
          expanded: FeatureEntrySpan(columns: 1, rows: 2),
        ),
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

  testWidgets('renders startup placeholders before bootstrap completes', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    expect(find.text('登录后查看课程'), findsOneWidget);
    expect(find.text('余额未刷新，请先登录一卡通'), findsOneWidget);
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

FeatureEntryDefinition _entry({
  required String id,
  required String title,
  required String subtitle,
  required IconData icon,
  required Color accentColor,
  required int sortOrder,
  FeatureEntryResponsiveSpan spans = const FeatureEntryResponsiveSpan(
    compact: FeatureEntrySpan(columns: 1, rows: 1),
    expanded: FeatureEntrySpan(columns: 1, rows: 1),
  ),
}) {
  return FeatureEntryDefinition(
    id: id,
    title: title,
    subtitle: subtitle,
    icon: icon,
    accentColor: accentColor,
    routeName: id,
    spans: spans,
    placements: const {FeatureEntryPlacement.homeLearning},
    sortOrder: sortOrder,
  );
}
