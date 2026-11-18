import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';
import 'package:jxu_campus_hub/core/semester/china_public_holidays.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_data_change_bus.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/core/theme/widgets/home_background_layer.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/home/home_page.dart';
import 'package:jxu_campus_hub/features/home/home_zone_controller.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_projection.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_sync.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/core/theme/widgets/home_ambient_background.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_asset_strip.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_event_banner.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';

import '../../helpers/credential_store_test_ext.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // 本文件按真实时钟构造课表：屏蔽法定节假日表，避免在假期运行时
    // 课程被首页当作放假。
    debugChinaPublicHolidaysOverride = const [];
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
    AppBootstrapController.instance.debugReset();
    CampusCardService.instance.debugSetCachedBalance(null);
    DormElectricityService.instance.debugReset();
    ExamService.instance.debugReset();
    GradesService.instance.debugReset();
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      now.year,
      now.month,
      now.day,
    );
    HomeZoneController.instance.updateZone(0);
    await ScheduleService.instance.debugClearCache();
    CampusWidgetSync.instance.debugSetDebounce(Duration.zero);
    CampusDataChangeBus.instance.debugReset();
    PageTransitionActivity.instance.debugReset();
  });

  tearDown(() {
    PageTransitionActivity.instance.debugReset();
    debugChinaPublicHolidaysOverride = null;
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
    // bootstrap 未就绪：资产行处于冷启动恢复态，不再是无信息量的 '--'。
    expect(find.text('正在恢复'), findsNWidgets(2));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('tapping logged-out hero opens academic login prompt', (
    tester,
  ) async {
    var promptCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          loginPromptPresenter: (_) async {
            promptCount++;
            return false;
          },
        ),
      ),
    );

    expect(find.text('去登录'), findsOneWidget);
    await tester.tap(find.text('登录后查看课程'));
    await tester.pump();

    expect(promptCount, 1);
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
      // 房间配置 / 余额缓存都要求 owner 标记与当前统一认证账号一致，
      // 否则首页按 fail closed 回落占位符。
      DormElectricityService.roomOwnerKey: 'casuser',
    });

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await CredentialStore.instance.saveUnifiedAuthSession('casuser');
    final cardEpoch = (await AuthSessionPersistence.instance.read(
      CredentialSessionDomain.unified,
    )).epoch;
    await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
      PrivateCacheEnvelope(
        owner: 'casuser',
        updatedAt: now,
        epoch: cardEpoch,
        payload: 23.5,
      ),
    );
    await CampusCardService.instance.restoreBalance();
    // 把开学日固定为今天，避免假期窗口运行时"明天"落在第 1 周之前。
    await SemesterCalendar.instance.setSemesterStartDate(now);
    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: now,
    );
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: studentId);
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
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
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

    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuser',
    });
    // 电费缓存与房间配置都归属当前统一认证账号，低电量投影才允许展示。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    DormElectricityService.instance.debugSetCachedElectricity(
      3.2,
      updatedAt: now,
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
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

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await CredentialStore.instance.saveZhengfangSession('2025000001');
    final epoch = (await AuthSessionPersistence.instance.read(
      CredentialSessionDomain.academic,
    )).epoch;
    final store = SharedPreferencesPrivateCacheStore(ExamService.cacheKey);
    await store.write(
      PrivateCacheEnvelope(
        owner: '2025000001',
        updatedAt: now,
        epoch: epoch,
        payload: [
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
        ],
      ),
    );
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
                kind: HomeAlertKind.lowElectricity,
                message: '宿舍剩余 5 度，电量偏低，建议及时充值',
                routeName: 'dorm-electricity',
              ),
              onTap: () => tapped++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('宿舍剩余 5 度，电量偏低，建议及时充值'), findsOneWidget);
    await tester.tap(find.text('宿舍剩余 5 度，电量偏低，建议及时充值'));
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
    expect(find.text('全部校园服务'), findsNothing);
    // 功能区内的「常用」分组（置顶 + 高频 + 默认补位）。
    expect(find.text('常用'), findsOneWidget);
    // 快捷入口行已并入功能区小按钮段落，使用口语化短标签（课表/成绩/考试/
    // 付款码/刷题），全称瓦片不再存在。「常用」只是快捷方式：默认常用
    // （课表/成绩/考试/一卡通/电费）在常用与原分类里各出现一次。
    expect(find.text('校园卡'), findsOneWidget);
    // 资产行 + 常用 + 校园生活分类。
    expect(find.text('宿舍电费'), findsNWidgets(3));
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('长按置顶'), findsOneWidget);
    expect(find.text('课表'), findsNWidgets(2));
    expect(find.text('成绩'), findsNWidgets(2));
    expect(find.text('考试'), findsNWidgets(2));
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
    PersonalizationController.instance.homeCampusNoticeEnabled.value = true;
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

    await tester.ensureVisible(find.text('考试').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('考试').first);
    await tester.pumpAndSettle();

    expect(find.text('考试安排页面'), findsOneWidget);
  });

  testWidgets('library function button opens the in-app library route', (
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

  testWidgets(
    'second classroom function button opens native subscription page',
    (tester) async {
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
    },
  );

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
    'maintains unboxed continuous layout without AppCard when background or shader is enabled',
    (tester) async {
      PersonalizationController.instance.shaderEnabled.value = true;

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.pump();
      // 流体 Shader 不依赖壁纸、持续动画，pumpAndSettle 不会收敛；推进固定时长即可。
      await tester.pump(const Duration(seconds: 1));

      // Even when shader/background is enabled, content sections stay unboxed without AppCard
      expect(find.byType(AppCard), findsNothing);
    },
  );

  testWidgets(
    'mounts hero fade gradient scrim overlay when background image is present',
    (tester) async {
      PersonalizationController.instance.backgroundImagePath.value =
          'test_bg.png';
      PersonalizationController.instance.shaderEnabled.value = true;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          home: const HomePage(),
        ),
      );
      // shader 滤镜有持续 ticker，不能 pumpAndSettle。
      await tester.pump();

      expect(_hasHeroFadeScrim(tester), isTrue);
      expect(find.byType(AppCard), findsNothing);

      PersonalizationController.instance.shaderEnabled.value = false;
      await tester.pump();

      expect(_hasHeroFadeScrim(tester), isFalse);
    },
  );

  testWidgets(
    'already-mounted home swaps ambient background when setter updates path',
    (tester) async {
      PersonalizationController.instance.shaderEnabled.value = false;
      PersonalizationController.instance.backgroundImagePath.value = null;

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.pump();

      expect(find.byType(HomeAmbientBackground), findsOneWidget);
      expect(find.byType(HomeBackgroundLayer), findsNothing);

      late final File file;
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('home_bg_live_');
        addTearDown(() => dir.delete(recursive: true));
        file = File('${dir.path}/bg.png');
        await file.writeAsBytes(_kOnePixelPng);
      });

      await PersonalizationController.instance.setBackgroundImagePath(
        file.path,
      );
      await tester.pump();

      final layer = tester.widget<HomeBackgroundLayer>(
        find.byType(HomeBackgroundLayer),
      );
      expect(layer.path, file.path);
      final image = tester.widget<Image>(
        find.descendant(
          of: find.byType(HomeBackgroundLayer),
          matching: find.byType(Image),
        ),
      );
      // Image.file 带 cacheWidth 时会被包成 ResizeImage(FileImage(...))：
      // 原图仍为 FileImage，仅解码尺寸受限（PRD §19）。
      final provider = image.image;
      final fileProvider = provider is ResizeImage
          ? provider.imageProvider
          : provider;
      expect(fileProvider, isA<FileImage>());
      expect((fileProvider as FileImage).file.path, file.path);
      expect(find.byType(HomeAmbientBackground), findsNothing);

      await PersonalizationController.instance.setBackgroundImagePath(null);
      await tester.pump();

      expect(find.byType(HomeAmbientBackground), findsOneWidget);
      expect(find.byType(HomeBackgroundLayer), findsNothing);
    },
  );

  testWidgets('campus data bus re-adopts memory cache without a new fetch', (
    tester,
  ) async {
    // 电费内存缓存按 owner 归属：先建立统一认证身份，注入值才可展示。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('42 度'), findsNothing);

    final bus = CampusDataChangeBus.instance;
    final revisionBefore = bus.revision.value;

    // 数据写入点只更新内存缓存并 ping 总线；首页应从缓存采纳，不发网络。
    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: DateTime.now(),
    );
    bus.notifyChanged();
    await tester.pump();

    expect(bus.revision.value, revisionBefore + 1);
    expect(find.text('42 度'), findsOneWidget);
    // 若走了网络会在 fake-async 区挂起并弹出错误，这里断言没有额外请求副作用。
    expect(find.byType(SnackBar), findsNothing);

    // 广播回调不再回写总线：没有 notify → fetch → notify 循环。
    await tester.pump();
    await tester.pump();
    expect(bus.revision.value, revisionBefore + 1);
  });

  testWidgets(
    'campus data bus ping during a page transition is applied only after it ends',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuser',
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      AppBootstrapController.instance.debugSetPhase(
        AppBootstrapPhase.localStateReady,
      );
      await tester.pump();
      await tester.pump();

      // 模拟「课表页 pop 回首页」的 220ms：转场进行中课表写缓存并 ping 总线。
      PageTransitionActivity.instance.acquire();
      DormElectricityService.instance.debugSetCachedElectricity(
        42,
        updatedAt: DateTime.now(),
      );
      CampusDataChangeBus.instance.notifyChanged();
      CampusDataChangeBus.instance.notifyChanged();
      await tester.pump();
      expect(find.text('42 度'), findsNothing, reason: '转场期间不重建首页');

      // 转场结束：补一次采纳，拿到最新缓存。
      PageTransitionActivity.instance.release();
      await tester.pump();
      await tester.pump();
      expect(find.text('42 度'), findsOneWidget);
    },
  );

  testWidgets(
    'returning from a pushed feature route waits for the pop transition',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuser',
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'home',
            builder: (context, state) => const HomePage(),
          ),
          GoRoute(
            path: '/campus-card',
            name: 'campus-card',
            builder: (context, state) => const Scaffold(body: Text('校园卡页面')),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
              },
            ),
          ),
          routerConfig: router,
          builder: (context, child) =>
              // ignore: deprecated_member_use -- 与 lib/app/app.dart 根层桥接保持一致
              MaterialUiCompatibilityBridge(child: child!),
        ),
      );
      AppBootstrapController.instance.debugSetPhase(
        AppBootstrapPhase.localStateReady,
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('校园卡'));
      await tester.pumpAndSettle();
      expect(find.text('校园卡页面'), findsOneWidget);

      // 返回：push 的 Future 在 pop 开始时就完成，但刷新 / 重建必须等转场落定。
      PageTransitionActivity.instance.acquire();
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('校园卡页面'), findsNothing);

      // 转场期间余额缓存更新（校园卡页内刷新落盘）：首页此刻不应响应。
      await _seedCampusCardBalance(
        now: DateTime.now(),
        account: 'casuser',
        balance: 88,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('¥88'), findsNothing, reason: '转场未落定，首页不应重建 / 刷新');

      PageTransitionActivity.instance.release();
      await tester.pumpAndSettle();
      expect(find.text('¥88'), findsOneWidget, reason: '转场落定后刷新采纳新余额');
    },
  );

  testWidgets('campus data bus projects cache and drops it when cache clears', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: DateTime.now(),
    );
    CampusDataChangeBus.instance.notifyChanged();
    await tester.pump();
    expect(find.text('42 度'), findsOneWidget);

    // 清空内存缓存后再广播：投影立刻回到占位符，证明只读缓存而非重新拉取。
    DormElectricityService.instance.debugSetCachedElectricity(null);
    CampusDataChangeBus.instance.notifyChanged();
    await tester.pump();

    expect(find.text('42 度'), findsNothing);
    // 电费无 owner 房间配置：回落「未设置」而非无信息量的 '--'。
    expect(find.text('未设置'), findsOneWidget);
    // 校园卡无明确统一认证持久身份：不再展示任何余额。
    expect(find.textContaining('¥'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'campus data bus update before hydrate is ignored until hydrate',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuser',
      );
      DormElectricityService.instance.debugSetCachedElectricity(
        42,
        updatedAt: DateTime.now(),
      );

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      // 尚未 hydrate：广播被跳过（不提前采纳投影）。
      CampusDataChangeBus.instance.notifyChanged();
      await tester.pump();
      // 缓存优先：电费已有通过 owner 校验的可展示值，冷启动照常显示，
      // 不被「正在恢复」遮住；只有没有值的校园卡显示恢复态。
      expect(find.text('42 度'), findsOneWidget);
      expect(find.text('正在恢复'), findsOneWidget);

      AppBootstrapController.instance.debugSetPhase(
        AppBootstrapPhase.localStateReady,
      );
      await tester.pump();
      await tester.pump();

      // hydrate 完成后同一广播即可被采纳（内存缓存仍在）。
      CampusDataChangeBus.instance.notifyChanged();
      await tester.pump();
      expect(find.text('42 度'), findsOneWidget);
    },
  );

  testWidgets('campus data bus listener is detached on dispose', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: DateTime.now(),
    );
    CampusDataChangeBus.instance.notifyChanged();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('mounted home drops prior owner private projection on logout', (
    tester,
  ) async {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));

    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuser',
    });
    await _seedPrivateProjection(
      now: now,
      account: 'casuser',
      studentId: '2025000001',
      balance: 23.5,
      examDate: tomorrow,
    );
    // 身份就绪后再注入电费缓存：owner 归属当前统一认证账号，才允许展示。
    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: now,
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);
    ScheduleService.instance.debugSetSnapshot(
      _scheduleSnapshotFor(
        studentId: '2025000001',
        now: now,
        weekday: tomorrow.weekday,
        courseName: '线性代数',
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('¥23.5'), findsOneWidget);
    expect(find.text('明天考试'), findsOneWidget);
    expect(find.text('微观经济学'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget);
    expect(find.text('42 度'), findsOneWidget);

    // 在别处登出统一认证：挂载中的首页必须同步按当前 owner 重新采纳投影，
    // 余额与电费都带归属校验 → 立即回落占位符，不保留上一身份的副本。
    UnifiedAuthService.instance.debugSetSession(active: false, account: null);
    UnifiedAuthService.instance.notifyListeners();
    await tester.pump();

    expect(find.text('¥23.5'), findsNothing);
    // 登出后无统一认证身份：两项都回落「待登录」，不保留上一身份副本。
    expect(find.text('待登录'), findsNWidgets(2));
    // 电费同为 owner 归属私有数据：随统一认证登出立即清空。
    expect(find.text('42 度'), findsNothing);
    // 教务身份未变：考试 / 课表仍属当前 owner，保持展示。
    expect(find.text('明天考试'), findsOneWidget);

    // 在别处登出教务：考试与课表投影一并回落，Hero 回到未登录态。
    ZhengfangAuth.instance.debugSetSession(active: false);
    ZhengfangAuth.instance.notifyListeners();
    await tester.pump();
    await tester.pump();

    expect(find.text('明天考试'), findsNothing);
    expect(find.text('微观经济学'), findsNothing);
    expect(find.text('线性代数'), findsNothing);
    expect(find.text('登录后查看课程'), findsOneWidget);
    expect(find.text('42 度'), findsNothing);
    expect(find.text('待登录'), findsNWidgets(2));
  });

  testWidgets('mounted home re-adopts projection for the new owner on switch', (
    tester,
  ) async {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));

    await _seedPrivateProjection(
      now: now,
      account: 'casuser',
      studentId: '2025000001',
      balance: 23.5,
      examDate: tomorrow,
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);
    ScheduleService.instance.debugSetSnapshot(
      _scheduleSnapshotFor(
        studentId: '2025000001',
        now: now,
        weekday: tomorrow.weekday,
        courseName: '线性代数',
      ),
    );
    ScheduleService.instance.debugSetSnapshot(
      _scheduleSnapshotFor(
        studentId: '2025000002',
        now: now,
        weekday: tomorrow.weekday,
        courseName: '高等数学 B',
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('¥23.5'), findsOneWidget);
    expect(find.text('微观经济学'), findsOneWidget);
    expect(find.text('线性代数'), findsOneWidget);

    // 切换到另一个统一认证账号：上一账号余额立即回落占位符。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser2',
    );
    UnifiedAuthService.instance.notifyListeners();
    await tester.pump();

    expect(find.text('¥23.5'), findsNothing);

    // 切换到另一个教务学号：上一学号的考试消失，投影改为新学号自己的缓存。
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000002',
    );
    ZhengfangAuth.instance.notifyListeners();
    await tester.pump();
    await tester.pump();

    expect(find.text('微观经济学'), findsNothing);
    expect(find.text('明天考试'), findsNothing);
    expect(find.text('线性代数'), findsNothing);
    expect(find.text('高等数学 B'), findsOneWidget);
    expect(find.text('今天没课 · 下一节'), findsOneWidget);
  });

  testWidgets('same-account unified relogin notify drops cached balance', (
    tester,
  ) async {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));

    await _seedPrivateProjection(
      now: now,
      account: 'casuser',
      studentId: '2025000001',
      balance: 23.5,
      examDate: tomorrow,
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('¥23.5'), findsOneWidget);

    // 同账号重登：身份与 revision 都不变，只有 notify（真实登录成功路径）；
    // 重登会销毁 epay 会话，首页不得继续展示重登前的余额副本。
    final revisionBefore = UnifiedAuthService.instance.sessionRevision;
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    UnifiedAuthService.instance.notifyListeners();
    await tester.pump();

    expect(UnifiedAuthService.instance.sessionRevision, revisionBefore);
    expect(find.text('¥23.5'), findsNothing);
    // 同账号重登：身份复位后本页补发刷新——校园卡进入真实获取中，电费无
    // 房间配置回落「未设置」（而非无信息量的 '--'）。
    expect(find.text('获取中'), findsOneWidget);
    expect(find.text('未设置'), findsOneWidget);
  });

  testWidgets(
    'late prior-owner balance response cannot restore stale content after logout',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuser',
      );
      await CredentialStore.instance.saveUnifiedAuthSession('casuser');

      final pending = Completer<double?>();
      CampusCardService.instance.debugBalanceFetcher = () => pending.future;
      addTearDown(() => CampusCardService.instance.debugBalanceFetcher = null);

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      AppBootstrapController.instance.debugSetPhase(
        AppBootstrapPhase.localStateReady,
      );
      await tester.pump();
      await tester.pump();

      // 余额查询仍在途：校园卡显示真实的「获取中」；电费请求排在校园卡之后
      // 尚未发起，是中性占位 '--'（不声称获取中）。
      expect(find.text('获取中'), findsOneWidget);
      expect(find.text('--'), findsOneWidget);

      // 登出后旧 owner 的响应才到达：认证世代已推进，结果一律不得写回。
      UnifiedAuthService.instance.debugSetSession(active: false, account: null);
      UnifiedAuthService.instance.notifyListeners();
      await tester.pump();

      pending.complete(23.5);
      await tester.pump();
      await tester.pump();

      expect(find.text('¥23.5'), findsNothing);
      expect(find.text('待登录'), findsNWidgets(2));
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'late prior-owner electricity response cannot leak into the new owner',
    (tester) async {
      final now = DateTime.now();

      SharedPreferences.setMockInitialValues({
        'dorm_epay_area_id': 'area',
        'dorm_epay_building_id': 'building',
        'dorm_epay_floor_id': 'floor',
        'dorm_epay_room_id': 'room',
        DormElectricityService.roomOwnerKey: 'casuserA',
      });
      await _seedCampusCardBalance(
        now: now,
        account: 'casuserA',
        balance: 23.5,
      );
      // A 的旧缓存已超过 30 分钟刷新窗口：先按 A 展示低电量，同时必然触发
      // 一次网络刷新（内存缓存已采纳，restoreCache 短路，不经过私有写队列）。
      DormElectricityService.instance.debugSetCachedElectricity(
        3.2,
        updatedAt: now.subtract(const Duration(minutes: 31)),
      );

      // A 的刷新悬挂在网关里，保持 in-flight。
      final pending = Completer<String>();
      final gateway = _PendingElectricityGateway(pending);
      DormElectricityService.instance.debugSetGateway(gateway);

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      AppBootstrapController.instance.debugSetPhase(
        AppBootstrapPhase.localStateReady,
      );
      await tester.pump();
      await _pumpUntil(tester, () => gateway.calls > 0);

      expect(gateway.calls, 1);
      // A 的过期低电量先展示：资产行 + 事件横幅。
      expect(find.text('¥23.5'), findsOneWidget);
      expect(find.text('3.20 度'), findsOneWidget);
      expect(find.textContaining('电量偏低'), findsOneWidget);

      // 换号到 B：上一账号电费与低电量横幅立即回落占位符。
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuserB',
      );
      UnifiedAuthService.instance.notifyListeners();
      await tester.pump();

      expect(find.text('¥23.5'), findsNothing);
      expect(find.text('3.20 度'), findsNothing);
      expect(find.textContaining('电量偏低'), findsNothing);
      // 换号后两项身份复位并由本页补发刷新：B 没有房间配置 → 电费「未设置」，
      // 校园卡没有 B 的余额 → 不再展示 A 的任何内容、也不停在 '获取中'。
      expect(find.text('未设置'), findsOneWidget);
      expect(find.text('获取中'), findsNothing);

      // A 的迟到响应（同为低电量 3.2 度）此时才返回：不得写回展示、事件
      // 横幅或桌面组件投影。
      pending.complete(
        '{"code":"200","msg":"SUC0000","data":{"balance_list":[{"id":"room","balance":"3.2"}]}}',
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(DormElectricityService.instance.cachedElectricity, isNull);
      expect(find.text('3.20 度'), findsNothing);
      expect(find.textContaining('电量偏低'), findsNothing);
      expect(find.text('未设置'), findsOneWidget);
      expect(find.text('获取中'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      final projection = buildCampusWidgetProjection();
      expect(projection.dormElectricity, '--');
      expect(projection.hasElectricityData, isFalse);
    },
  );

  testWidgets('legacy unowned dorm config never projects on home', (
    tester,
  ) async {
    final now = DateTime.now();

    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      // 历史遗留数据：房间配置 / 余额都在，但没有 owner 标记。
      'dorm_cached_electricity': 42.0,
      'dorm_cached_electricity_updated_at': now.millisecondsSinceEpoch,
    });
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    // 无 owner 标记的磁盘数据不得被采纳：服务内存缓存保持为空，首页资产行
    // 与桌面组件投影都回落占位符（磁盘数据保留但不展示）。
    expect(DormElectricityService.instance.cachedElectricity, isNull);
    expect(DormElectricityService.instance.hasFreshCache, isFalse);
    expect(find.text('42 度'), findsNothing);
    // 无 owner 房间配置 → 电费明确「未设置」；校园卡无余额 → 不展示 '¥'。
    expect(find.text('未设置'), findsOneWidget);
    expect(find.textContaining('¥'), findsNothing);

    final projection = buildCampusWidgetProjection();
    expect(projection.dormElectricity, '--');
    expect(projection.hasElectricityData, isFalse);
  });

  testWidgets(
    'cold load shows 获取中 for both assets, then success stops loading',
    (tester) async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'dorm_epay_area_id': 'area',
        'dorm_epay_building_id': 'building',
        'dorm_epay_floor_id': 'floor',
        'dorm_epay_room_id': 'room',
        DormElectricityService.roomOwnerKey: 'casuser',
      });
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuser',
      );
      await CredentialStore.instance.saveUnifiedAuthSession('casuser');

      // 两条真实请求都悬停在网络层，确定性制造「真正获取中」。
      final cardPending = Completer<double?>();
      CampusCardService.instance.debugBalanceFetcher = () => cardPending.future;
      addTearDown(() => CampusCardService.instance.debugBalanceFetcher = null);
      final electricityPending = Completer<String>();
      DormElectricityService.instance.debugSetGateway(
        _PendingElectricityGateway(electricityPending),
      );
      await SemesterCalendar.instance.setSemesterStartDate(now);

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      AppBootstrapController.instance.debugSetPhase(
        AppBootstrapPhase.localStateReady,
      );
      await tester.pump();
      await tester.pump();

      // 冷启动无缓存：电费请求在校园卡请求完成后才发起（`_refreshDeferredContent`
      // 先 await 校园卡），因此此刻只有校园卡是真实在途（「获取中」+ 转圈）；
      // 电费是静态「准备中」（preparing），显示中性占位 '--'，不转圈。
      expect(find.text('获取中'), findsOneWidget);
      expect(find.text('--'), findsOneWidget);
      expect(find.text('待登录'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      cardPending.complete(23.5);
      await tester.pump();
      await tester.pump();

      expect(find.text('¥23.5'), findsOneWidget);
      // 校园卡就绪后电费请求才发起：此刻电费真实在途，保留「获取中」和它的转圈。
      expect(find.text('获取中'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      electricityPending.complete(
        '{"code":"200","msg":"SUC0000","data":{"balance_list":[{"id":"room","balance":"42"}]}}',
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('42 度'), findsOneWidget);
      expect(find.text('获取中'), findsNothing);
      expect(find.text('--'), findsNothing);
      // 请求结束：停止一切加载指示。
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('cached value keeps showing while a background refresh runs', (
    tester,
  ) async {
    final now = DateTime.now();
    // 电费：房间配置 + 刚过期的缓存值 → 触发后台刷新但保留旧值。
    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuser',
    });
    await _seedCampusCardBalance(now: now, account: 'casuser', balance: 23.5);
    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: now.subtract(const Duration(minutes: 31)),
    );
    final electricityPending = Completer<String>();
    DormElectricityService.instance.debugSetGateway(
      _PendingElectricityGateway(electricityPending),
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    // 余额走新鲜缓存短路，电费旧值在后台刷新：两项都保留真实数值，绝不出现 '--'。
    expect(find.text('¥23.5'), findsOneWidget);
    expect(find.text('42 度'), findsOneWidget);
    expect(find.text('--'), findsNothing);
    expect(find.text('获取中'), findsNothing);
    // 有缓存后台刷新时，数值旁的小转圈表达「正在刷新」。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    electricityPending.complete(
      '{"code":"200","msg":"SUC0000","data":{"balance_list":[{"id":"room","balance":"42"}]}}',
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('42 度'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('asset failure keeps the other asset and retry recovers', (
    tester,
  ) async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuser',
    });
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await CredentialStore.instance.saveUnifiedAuthSession('casuser');
    // 校园卡请求直接失败；电费走缓存就绪。
    CampusCardService.instance.debugBalanceFetcher = () async {
      throw StateError('card down');
    };
    addTearDown(() => CampusCardService.instance.debugBalanceFetcher = null);
    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: now,
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    // 校园卡获取失败 → 「获取失败」；电费不受影响，仍展示就绪值。
    await _pumpUntil(tester, () => find.text('获取失败').evaluate().isNotEmpty);
    expect(find.text('获取失败'), findsOneWidget);
    expect(find.text('42 度'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // 失败停止加载：不再有任何转圈。
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 点按失败项 → 受控重试；恢复后展示新值（重试期间也不残留转圈）。
    CampusCardService.instance.debugBalanceFetcher = () async => 12.5;
    await tester.tap(find.text('获取失败'));
    await tester.pump();
    await tester.pump();

    expect(find.text('获取失败'), findsNothing);
    expect(find.text('¥12.5'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('rapid taps on 获取失败 start only one retry request', (
    tester,
  ) async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuser',
    });
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await CredentialStore.instance.saveUnifiedAuthSession('casuser');
    var calls = 0;
    CampusCardService.instance.debugBalanceFetcher = () async {
      calls++;
      throw StateError('card down');
    };
    addTearDown(() => CampusCardService.instance.debugBalanceFetcher = null);
    DormElectricityService.instance.debugSetCachedElectricity(
      42,
      updatedAt: now,
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await _pumpUntil(tester, () => find.text('获取失败').evaluate().isNotEmpty);
    expect(find.text('获取失败'), findsOneWidget);
    final callsBeforeRetry = calls;

    // 重试请求悬停；同一帧内连点多次（树尚未重建）只允许发出一条请求。
    final pending = Completer<double?>();
    CampusCardService.instance.debugBalanceFetcher = () {
      calls++;
      return pending.future;
    };
    final target = find.text('获取失败');
    await tester.tap(target);
    await tester.tap(target);
    await tester.tap(target);
    await tester.pump();

    expect(calls, callsBeforeRetry + 1);
    expect(find.text('获取中'), findsOneWidget);

    pending.complete(12.5);
    await tester.pump();
    await tester.pump();
    expect(find.text('¥12.5'), findsOneWidget);
    expect(calls, callsBeforeRetry + 1);
  });

  testWidgets(
    'login after logged-out start triggers asset refresh (no stuck preparing)',
    (tester) async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      CampusCardService.instance.debugBalanceFetcher = () async {
        calls++;
        return 12.5;
      };
      addTearDown(() => CampusCardService.instance.debugBalanceFetcher = null);
      await SemesterCalendar.instance.setSemesterStartDate(now);

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      AppBootstrapController.instance.debugSetPhase(
        AppBootstrapPhase.localStateReady,
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('待登录'), findsNWidgets(2));
      expect(calls, 0);

      // 登录：身份变化后本页自己补发一次资产刷新（不依赖其它调度器），
      // 资产行不会停在 '--'（preparing）。
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuser',
      );
      await CredentialStore.instance.saveUnifiedAuthSession('casuser');
      UnifiedAuthService.instance.notifyListeners();
      await _pumpUntil(tester, () => calls > 0);
      await tester.pump();
      await tester.pump();

      expect(calls, 1);
      expect(find.text('¥12.5'), findsOneWidget);
      // 电费无房间配置：落到「未设置」，而不是一直 '--'。
      expect(find.text('未设置'), findsOneWidget);
      expect(find.text('--'), findsNothing);
    },
  );

  testWidgets('系统「移除动画」下恢复态为静态文案，无持续转圈', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();

    expect(find.text('正在恢复'), findsNWidgets(2));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('系统「移除动画」下真实获取中降级为静态点，不持续转圈', (tester) async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuser',
    });
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await CredentialStore.instance.saveUnifiedAuthSession('casuser');

    final cardPending = Completer<double?>();
    CampusCardService.instance.debugBalanceFetcher = () => cardPending.future;
    addTearDown(() => CampusCardService.instance.debugBalanceFetcher = null);
    DormElectricityService.instance.debugSetGateway(
      _PendingElectricityGateway(Completer<String>()),
    );
    await SemesterCalendar.instance.setSemesterStartDate(now);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: HomePage()),
      ),
    );
    AppBootstrapController.instance.debugSetPhase(
      AppBootstrapPhase.localStateReady,
    );
    await tester.pump();
    await tester.pump();

    // 真实在途，但系统要求移除动画：静态文案表达状态，不出现持续转圈。
    // （电费尚未发起请求，是中性占位 '--'。）
    expect(find.text('获取中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

/// 1×1 透明 PNG，给 Image.file 一条真实可读路径。
const _kOnePixelPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

bool _hasHeroFadeScrim(WidgetTester tester) {
  return tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).any((box) {
    final decoration = box.decoration;
    if (decoration is! BoxDecoration) return false;
    final gradient = decoration.gradient;
    return gradient is LinearGradient && gradient.stops?.length == 5;
  });
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

/// 写入 owner 明确的统一认证 / 教务持久身份与私有缓存，并让服务恢复进内存：
/// 首页 hydrate 后即可展示「上一身份」的余额与考试投影。
Future<void> _seedPrivateProjection({
  required DateTime now,
  required String account,
  required String studentId,
  required double balance,
  required DateTime examDate,
}) async {
  UnifiedAuthService.instance.debugSetSession(active: true, account: account);
  await CredentialStore.instance.saveUnifiedAuthSession(account);
  final cardEpoch = (await AuthSessionPersistence.instance.read(
    CredentialSessionDomain.unified,
  )).epoch;
  await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
    PrivateCacheEnvelope(
      owner: account,
      updatedAt: now,
      epoch: cardEpoch,
      payload: balance,
    ),
  );
  await CampusCardService.instance.restoreBalance();

  ZhengfangAuth.instance.debugSetSession(active: true, studentId: studentId);
  await CredentialStore.instance.saveZhengfangSession(studentId);
  final examEpoch = (await AuthSessionPersistence.instance.read(
    CredentialSessionDomain.academic,
  )).epoch;
  final dateText =
      '${examDate.year}-'
      '${examDate.month.toString().padLeft(2, '0')}-'
      '${examDate.day.toString().padLeft(2, '0')}';
  await SharedPreferencesPrivateCacheStore(ExamService.cacheKey).write(
    PrivateCacheEnvelope(
      owner: studentId,
      updatedAt: now,
      epoch: examEpoch,
      payload: [
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
      ],
    ),
  );
  await ExamService.instance.restoreCache();
}

/// 指定学号、指定星期几的一门课快照（时间戳取 [now]，视为刚刷新）。
ScheduleCacheSnapshot _scheduleSnapshotFor({
  required String studentId,
  required DateTime now,
  required int weekday,
  required String courseName,
}) {
  return ScheduleCacheSnapshot(
    studentId: studentId,
    termContext: ScheduleTermContext.current(now),
    courses: [
      CourseEntry(
        courseName: courseName,
        teacherName: '张老师',
        weekday: weekday,
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
  );
}

/// 有界推进 pump：直到 [condition] 满足或达到 [maxPumps]（每次推进 10ms）。
/// 避免依赖固定 pump 次数在 FakeAsync 下变得脆弱，同时保证永不无限等待。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 40,
}) async {
  for (var i = 0; i < maxPumps && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// 只写入校园卡余额的 owner 私有缓存并恢复进内存：hydrate 后余额走缓存
/// 短路，不触发网络，让测试聚焦电费链路。
Future<void> _seedCampusCardBalance({
  required DateTime now,
  required String account,
  required double balance,
}) async {
  UnifiedAuthService.instance.debugSetSession(active: true, account: account);
  await CredentialStore.instance.saveUnifiedAuthSession(account);
  final cardEpoch = (await AuthSessionPersistence.instance.read(
    CredentialSessionDomain.unified,
  )).epoch;
  await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
    PrivateCacheEnvelope(
      owner: account,
      updatedAt: now,
      epoch: cardEpoch,
      payload: balance,
    ),
  );
  await CampusCardService.instance.restoreBalance();
}

/// 悬挂的电费网关：`call` 直到测试显式 complete 才返回，用于制造
/// 「A 在途刷新 → 换号到 B → A 迟到响应」的确定性竞态。
class _PendingElectricityGateway implements Epay100Gateway {
  _PendingElectricityGateway(this.pending);

  final Completer<String> pending;
  int calls = 0;

  @override
  Future<String> call(String method, Map<String, String> data) {
    calls++;
    return pending.future;
  }

  @override
  Future<void> invalidate() async {}

  @override
  void debugReset() {}
}
