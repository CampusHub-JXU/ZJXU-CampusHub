import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/home/home_page.dart';
import 'package:jxu_campus_hub/features/home/home_zone_controller.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_asset_strip.dart';
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
    PersonalizationController.instance.shaderEnabled.value = false;
    PersonalizationController.instance.backgroundImagePath.value = null;
    // 单例注入点在页面 dispose 时置空；这里兜底防止失败用例泄漏。
    HomeZoneController.instance
      ..scrollToTop = null
      ..scrollToFunction = null;
  });

  /// 手机尺寸视口：ScrollSpy 判定依赖真实的首屏/视口比例。可传高度压矮
  /// 视口制造滚动空间（新布局整页约一屏高，滚动行为测试需要溢出内容）。
  void usePhoneSurface(WidgetTester tester, {double height = 900}) {
    tester.view.physicalSize = Size(412, height);
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
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
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
    // 今天无课：Hero 以课程大字承接明天第一节课（kicker「今天没课 · 下一节」，
    // 日期并入时间行）；明天仅此一门，Today 段落整段消失、不重复 Hero 信息。
    expect(find.text('今天没课 · 下一节'), findsOneWidget);
    expect(find.text('明天 08:00'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget);
    expect(find.text('明天'), findsNothing);
  });

  testWidgets('before semester start previews first-day courses', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 开学日固定取下一个周一：isBeforeSemesterStart 判定「今天早于开学
    // 日所在周的第 1 周周一」，写死「今天 + 2 天」在周一~周三运行时会
    // 落进同一周而不再属于未开学；倒计时天数按运行日动态计算。
    final semesterStart = _nextMonday(today);
    final countdownDays = semesterStart.difference(today).inDays;

    await SemesterCalendar.instance.setSemesterStartDate(semesterStart);
    ScheduleService.instance.debugSetSnapshot(
      ScheduleCacheSnapshot(
        studentId: '2025000001',
        termContext: ScheduleTermContext.current(now),
        courses: [
          CourseEntry(
            courseName: '高等数学 B',
            teacherName: '张老师',
            weekday: semesterStart.weekday,
            startLesson: 1,
            endLesson: 2,
            weekRange: '1-2周',
            classroom: '教B-102',
            campus: '梁林校区',
            typeSymbol: '',
          ),
          CourseEntry(
            courseName: '大学英语',
            teacherName: '李老师',
            weekday: semesterStart.weekday,
            startLesson: 3,
            endLesson: 4,
            weekRange: '1-2周',
            classroom: '外B-305',
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

    // Hero 未开学倒计时：环境行省略状态段、kicker「未开学」不再渲染，
    // 全屏「开学」语义只出现在倒计时大字与「开学首日」标题两处；
    // 课程详情只出现在「开学首日」预览段落。
    expect(find.text('距离开学还有 $countdownDays 天'), findsOneWidget);
    expect(find.text('未开学'), findsNothing);
    expect(
      find.text('${semesterStart.month}月${semesterStart.day}日'),
      findsOneWidget,
    );
    expect(find.text('开学首日'), findsOneWidget);
    expect(find.text('高等数学 B'), findsOneWidget);
    expect(find.text('大学英语'), findsOneWidget);
    // 未超过 3 条：不渲染「查看全部」截断尾行。
    expect(find.text('查看全部'), findsNothing);
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

    // Hero 保留给课表状态（今天没课时下一节课仍以课程大字展示），
    // 低电量升级为事件横幅；资产行数值同步告警。
    expect(find.text('今天没课 · 下一节'), findsOneWidget);
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

  testWidgets('renders first screen with unified function buttons', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    // 旧版首页区块已删除。
    expect(find.text('本周'), findsNothing);
    expect(find.text('常用'), findsNothing);
    expect(find.text('全部校园服务'), findsNothing);
    // 快捷入口行已并入功能区小按钮段落：全部入口只出现一次，使用口语化
    // 短标签（课表/成绩/考试/付款码/刷题），全称瓦片不再存在。
    expect(find.text('校园卡'), findsOneWidget);
    expect(find.text('宿舍电费'), findsNWidgets(2));
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('长按置顶'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('成绩'), findsOneWidget);
    expect(find.text('考试'), findsOneWidget);
    expect(find.text('付款码'), findsOneWidget);
    expect(find.text('成绩查询'), findsNothing);
    expect(find.text('考试安排'), findsNothing);
    expect(find.text('图书馆'), findsOneWidget);
    expect(find.text('第二课堂'), findsOneWidget);
  });

  testWidgets('dock zone controller scrolls to function anchor', (
    tester,
  ) async {
    // 压矮视口：整页约一屏高，只有内容溢出时「滚到功能区」才可观测。
    usePhoneSurface(tester, height: 600);
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
    usePhoneSurface(tester, height: 600);
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

  testWidgets('campus notice follows asset strip and precedes function zone', (
    tester,
  ) async {
    usePhoneSurface(tester);
    addTearDown(NoticeSyncStore.instance.debugReset);
    NoticeSyncStore.instance.debugReset();
    // 直接注入收件箱头（纯内存）：commitSync 涉及真实文件锁，在
    // testWidgets 的假异步区里无法完成；本测试只关心布局结果。
    NoticeSyncStore.instance.inboxHead.value = NoticeInboxHead(
      latest: [
        _notice('1', date: '2026-09-04'),
        _notice('2', date: '2026-08-30'),
        _notice('3', date: '2026-07-13'),
      ],
      unreadIds: {'1', '2', '3'},
      unreadCount: 3,
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();
    await tester.pumpAndSettle();

    // 公告紧随资产行（仅隔一个段落间距），不再被弹性留白压到首屏底部；
    // 功能区段落仍在公告之后。
    final assetBottom = tester.getBottomRight(find.byType(HomeAssetStrip)).dy;
    // 「校园公告」在公告区块头与功能区按钮中各出现一次，取树序第一份。
    final noticeTop = tester.getTopLeft(find.text('校园公告').first).dy;
    final functionTop = tester.getTopLeft(find.text('功能')).dy;
    expect(noticeTop, greaterThan(assetBottom));
    expect(noticeTop - assetBottom, lessThan(60));
    expect(functionTop, greaterThan(noticeTop));
  });

  testWidgets('exam function button navigates to dedicated exam entry', (
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

    await tester.ensureVisible(find.text('考试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('考试'));
    await tester.pumpAndSettle();

    expect(find.text('考试安排页面'), findsOneWidget);
  });

  testWidgets('library function button navigates to dedicated library entry', (
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

  testWidgets('second classroom function button navigates to dedicated entry', (
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

  testWidgets(
    'keeps home content sections unboxed when background is not enabled',
    (tester) async {
      PersonalizationController.instance.shaderEnabled.value = false;
      PersonalizationController.instance.backgroundImagePath.value = null;

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.pump();
      await tester.pumpAndSettle();

      // In default ambient background, Hero and sections are unboxed without AppCard
      expect(find.byType(AppCard), findsNothing);
    },
  );

  testWidgets(
    'wraps content sections in frosted AppCard when fluid background is enabled',
    (tester) async {
      PersonalizationController.instance.shaderEnabled.value = true;

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.pump();
      await tester.pumpAndSettle();

      // When fluid/shader background is enabled, content sections receive frosted glass AppCard wrappers
      final cards = tester.widgetList<AppCard>(find.byType(AppCard));
      expect(cards.isNotEmpty, isTrue);
      expect(cards.every((card) => card.glassEnabled), isTrue);
    },
  );
}

double _scrollOffset(WidgetTester tester) {
  final scrollable = tester.state<ScrollableState>(
    find.byType(Scrollable).first,
  );
  return scrollable.position.pixels;
}

Notice _notice(String id, {String? date}) => Notice(
  title: '通知$id',
  url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=$id',
  category: '通知公告',
  date: date ?? '2026-09-01',
);

/// 下一个周一（今天恰为周一则取下周一），保证严格晚于今天。
DateTime _nextMonday(DateTime today) {
  final delta = (DateTime.monday - today.weekday) % 7;
  final next = today.add(Duration(days: delta == 0 ? 7 : delta));
  return DateTime(next.year, next.month, next.day);
}
