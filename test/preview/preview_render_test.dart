import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_page.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_page.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';

import 'package:jxu_campus_hub/features/home/home_page.dart';
import 'package:jxu_campus_hub/features/my/my_page.dart';
import 'package:jxu_campus_hub/features/notification_center/notification_center_page.dart';

import 'package:jxu_campus_hub/features/settings/appearance_page.dart';
import 'package:jxu_campus_hub/features/settings/personalization_page.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';
import 'package:jxu_campus_hub/shared/widgets/app_app_bar.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';
import 'package:jxu_campus_hub/shared/widgets/app_empty_view.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';
import 'package:jxu_campus_hub/shared/widgets/app_icon_badge.dart';
import 'package:jxu_campus_hub/shared/widgets/app_search_field.dart';
import 'package:jxu_campus_hub/shared/widgets/app_tile_surface.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_nav_bar.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';

import '../helpers/test_setup.dart';
import '../helpers/preview_support.dart';
import '../helpers/credential_store_test_ext.dart';

/// 视觉预览渲染（预渲染脚本）。
///
/// `flutter test` 默认运行时全部 skip（零副作用）；由
/// `tools/render_previews.ps1` 设置 `JXU_PREVIEW_RENDER=1` 并配合
/// `flutter test --update-goldens test/preview/preview_render_test.dart`
/// 把每个场景渲染为 `preview/render/*.png`。
///
/// 目的：视觉重构时让所有页面/组件共用同一套渲染产物做验收基准，
/// 避免每个页面各设计各的。
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    // 字体加载依赖真实事件循环，必须在 FakeAsync 之外完成（见
    // test/helpers/preview_support.dart 的 pumpPreviewScene 注释）。
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  void previewTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await resetTestEnvironment();
      AppBootstrapController.instance.debugReset();
      await body(tester);
    }, skip: !renderEnabled);
  }

  Future<void> renderPage(
    WidgetTester tester,
    String name,
    Widget page, {
    Brightness brightness = Brightness.light,
    Size? logicalSize,
  }) async {
    await pumpPreviewScene(
      tester,
      (_) => page,
      brightness: brightness,
      logicalSize: logicalSize,
    );
    await expectPreviewGolden(tester, name);
  }

  // ── 组件画廊 ────────────────────────────────────────────────────────────

  previewTest('gallery_light', (tester) async {
    await pumpPreviewScene(
      tester,
      (_) => _ComponentGallery(),
      logicalSize: const Size(412, 3140),
    );
    await expectPreviewGolden(tester, 'gallery_light');
  });

  previewTest('gallery_dark', (tester) async {
    await pumpPreviewScene(
      tester,
      (_) => _ComponentGallery(),
      brightness: Brightness.dark,
      logicalSize: const Size(412, 3140),
    );
    await expectPreviewGolden(tester, 'gallery_dark');
  });

  previewTest('glass_tiers_backdrop_light', (tester) async {
    await pumpPreviewScene(tester, (_) => _GlassTiersBackdropScene());
    await expectPreviewGolden(tester, 'glass_tiers_backdrop_light');
  });

  previewTest('appbar_scroll_under_light', (tester) async {
    await pumpPreviewScene(tester, (_) => _AppBarScrollUnderScene());
    await expectPreviewGolden(tester, 'appbar_scroll_under_light');
  });

  previewTest('nav_shell_light', (tester) async {
    await pumpPreviewScene(tester, (_) => _NavShellScene());
    await expectPreviewGolden(tester, 'nav_shell_light');
  });

  // ── 真实页面（离线真实状态）─────────────────────────────────────────────

  previewTest('page_home_light', (tester) async {
    await renderPage(tester, 'page_home_light', const HomePage());
  });

  previewTest('page_home_dark', (tester) async {
    await renderPage(
      tester,
      'page_home_dark',
      const HomePage(),
      brightness: Brightness.dark,
    );
  });

  previewTest('page_home_glass_off', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await renderPage(tester, 'page_home_glass_off', const HomePage());
  });

  // 首页富状态：种子课程/考试/余额（超高视口一次性呈现全部信息分区）。
  previewTest('page_home_rich_light', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedRichHomeState();
    await renderPage(
      tester,
      'page_home_rich_light',
      const HomePage(),
      logicalSize: const Size(412, 1720),
    );
  });

  previewTest('page_home_rich_dark', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedRichHomeState();
    await renderPage(
      tester,
      'page_home_rich_dark',
      const HomePage(),
      brightness: Brightness.dark,
      logicalSize: const Size(412, 1720),
    );
  });

  // 假期首页（未开学 + 有课表缓存）：Hero 开学倒计时 + 「开学首日」
  // 次日预览列表把功能区压到视口外，覆盖"无课时上半屏空置"的形态。
  previewTest('page_home_break_light', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedBreakHomeState();
    await renderPage(
      tester,
      'page_home_break_light',
      const HomePage(),
      logicalSize: const Size(412, 1720),
    );
  });

  previewTest('page_home_break_dark', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedBreakHomeState();
    await renderPage(
      tester,
      'page_home_break_dark',
      const HomePage(),
      brightness: Brightness.dark,
      logicalSize: const Size(412, 1720),
    );
  });

  // 功能区（首页底部 Bento 段落）滚动态：整页内容在 SingleChildScrollView
  // 中一次性构建，ensureVisible 直接定位到段落头。
  Future<void> renderHomeFunctionScene(
    WidgetTester tester,
    String name, {
    Brightness brightness = Brightness.light,
  }) async {
    await pumpPreviewScene(
      tester,
      (_) => const HomePage(),
      brightness: brightness,
      logicalSize: const Size(412, 1720),
    );
    await tester.ensureVisible(find.text('长按置顶'));
    await tester.pumpAndSettle();
    await expectPreviewGolden(tester, name);
  }

  previewTest('page_home_function_light', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedRichHomeState();
    await renderHomeFunctionScene(tester, 'page_home_function_light');
  });

  previewTest('page_home_function_dark', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedRichHomeState();
    await renderHomeFunctionScene(
      tester,
      'page_home_function_dark',
      brightness: Brightness.dark,
    );
  });

  // 首页公告开屏形态：富状态 + 注入收件箱头 + 悬浮 dock 外壳——
  // 验收点：第二条公告被 dock 顶缘截断在半行，公告块不压到 dock 之下；
  // 「校园公告」标题行与最新一条完整可见。
  previewTest('page_home_notice_light', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedRichHomeState();
    addTearDown(NoticeSyncStore.instance.debugReset);
    NoticeSyncStore.instance.debugReset();
    NoticeSyncStore.instance.inboxHead.value = _previewNoticeHead();
    await pumpPreviewScene(tester, (_) => const _HomeDockScene());
    await expectPreviewGolden(tester, 'page_home_notice_light');
  });

  previewTest('page_home_notice_dark', (tester) async {
    await GlassStyleController.instance.setEnabled(true);
    await _seedRichHomeState();
    addTearDown(NoticeSyncStore.instance.debugReset);
    NoticeSyncStore.instance.debugReset();
    NoticeSyncStore.instance.inboxHead.value = _previewNoticeHead();
    await pumpPreviewScene(
      tester,
      (_) => const _HomeDockScene(),
      brightness: Brightness.dark,
    );
    await expectPreviewGolden(tester, 'page_home_notice_dark');
  });

  previewTest('page_my_light', (tester) async {
    await renderPage(tester, 'page_my_light', const MyPage());
  });

  // ── 通知中心：搜索框 + 双 Tab（收件箱经磁盘状态文件离线 seed）───────────
  previewTest('page_notification_center_light', (tester) async {
    await _seedNotificationCenterInbox();
    await renderPage(
      tester,
      'page_notification_center_light',
      const NotificationCenterPage(),
    );
  });

  previewTest('page_notification_center_dark', (tester) async {
    await _seedNotificationCenterInbox();
    await renderPage(
      tester,
      'page_notification_center_dark',
      const NotificationCenterPage(),
      brightness: Brightness.dark,
    );
  });

  // 搜索过滤形态：输入「竞赛」后列表只剩命中项、隐藏「全部已读」表头。
  previewTest('page_notification_center_search_light', (tester) async {
    await _seedNotificationCenterInbox();
    await pumpPreviewScene(tester, (_) => const NotificationCenterPage());
    await tester.enterText(find.byType(TextField).first, '竞赛');
    await tester.pump();
    await expectPreviewGolden(tester, 'page_notification_center_search_light');
  });

  previewTest('page_settings_light', (tester) async {
    await renderPage(tester, 'page_settings_light', const SettingsPage());
  });

  // 设置页整页形态（高视口一次呈现全部分组）：分组层级、脚注节奏、
  // 版本行与手机限宽基线。
  previewTest('page_settings_full_light', (tester) async {
    await renderPage(
      tester,
      'page_settings_full_light',
      const SettingsPage(),
      logicalSize: const Size(412, 1800),
    );
  });

  previewTest('page_settings_full_dark', (tester) async {
    await renderPage(
      tester,
      'page_settings_full_dark',
      const SettingsPage(),
      brightness: Brightness.dark,
      logicalSize: const Size(412, 1800),
    );
  });

  // 宽屏限宽形态：内容列居中限宽（SettingsPage 内容最大宽度），两侧留白。
  previewTest('page_settings_wide_light', (tester) async {
    await renderPage(
      tester,
      'page_settings_wide_light',
      const SettingsPage(),
      logicalSize: const Size(900, 1400),
    );
  });

  previewTest('page_appearance_light', (tester) async {
    await renderPage(tester, 'page_appearance_light', const AppearancePage());
  });

  // 个性化：展开 Shader 滑条，超高视口一次呈现三个分组。
  previewTest('page_personalization_light', (tester) async {
    await PersonalizationController.instance.setShaderEnabled(true);
    await renderPage(
      tester,
      'page_personalization_light',
      const PersonalizationPage(),
      logicalSize: const Size(412, 1500),
    );
  });

  previewTest('page_personalization_dark', (tester) async {
    await PersonalizationController.instance.setShaderEnabled(true);
    await renderPage(
      tester,
      'page_personalization_dark',
      const PersonalizationPage(),
      brightness: Brightness.dark,
      logicalSize: const Size(412, 1500),
    );
  });

  // 说明：GradesPage / SchedulePage 在离线场景下会遗留网络重试 Timer，
  // 触发 flutter_test 的 pending-timer 断言，不适合放进无登录预览；
  // 它们的未登录态与 campus_card / AuthRequiredView 一致，画廊已覆盖。

  previewTest('page_campus_card_light', (tester) async {
    await renderPage(tester, 'page_campus_card_light', const CampusCardPage());
  });

  // 单值详情页（design-guidelines 4.7）：无框读数 + 三格动作，校园卡与电费
  // 同一套骨架，靠富状态种子的新鲜缓存离线渲染。
  for (final brightness in Brightness.values) {
    final suffix = brightness.name;
    previewTest('page_campus_card_detail_$suffix', (tester) async {
      await GlassStyleController.instance.setEnabled(true);
      await _seedRichHomeState();
      await renderPage(
        tester,
        'page_campus_card_detail_$suffix',
        const CampusCardPage(),
        brightness: brightness,
      );
    });

    previewTest('page_dorm_electricity_detail_$suffix', (tester) async {
      await GlassStyleController.instance.setEnabled(true);
      await _seedRichHomeState();
      // 寝室配置须带当前账号 owner 标记，否则页面按未配置处理。
      await DormElectricityService.instance.saveRoomConfig(
        const DormRoomConfig(
          areaId: 'area',
          buildingId: 'building',
          floorId: 'floor',
          roomId: 'room',
        ),
      );
      DormElectricityService.instance.debugSetCachedElectricity(
        27.4,
        updatedAt: DateTime.now(),
      );
      await renderPage(
        tester,
        'page_dorm_electricity_detail_$suffix',
        const DormElectricityPage(),
        brightness: brightness,
      );
    });
  }
}

/// 预览公告条目：id 取 wbnewsid（与线上解析规则一致，未读集合靠它对上）。
Notice _previewNotice(String newsId, String title, String date) => Notice(
  title: title,
  url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=$newsId',
  category: '通知公告',
  date: date,
);

/// 预览收件箱头：3 条公告（前两条未读），与线上解析的 id 规则一致。
NoticeInboxHead _previewNoticeHead() => NoticeInboxHead(
  latest: [
    _previewNotice('n1', '关于开展2026年秋季学期教材征订工作的通知', '2026-09-04'),
    _previewNotice('n2', '2025、2026级学生2026-2027学年第一学期备考提醒', '2026-08-30'),
    _previewNotice('n3', '关于图书馆调整暑期开放时间的通知', '2026-07-13'),
  ],
  unreadIds: const {'n1', 'n2'},
  unreadCount: 2,
);

/// 通知中心收件箱种子：直接注入内存态并短路 reload（真实文件锁与磁盘
/// I/O 在测试的假异步区永远不会完成，页面 initState 的 reload 会挂到
/// 超时）。标题覆盖两种类型与可搜索关键词（「竞赛」）。
Future<void> _seedNotificationCenterInbox() async {
  addTearDown(NoticeSyncStore.instance.debugReset);
  NoticeSyncStore.instance.debugReset();
  const unreadIds = {'21001', '21003', '21005'};
  final notices = [
    const Notice(
      title: '关于举办2026年大学生程序设计竞赛校内选拔的通知',
      url: 'https://jwc.zjxu.edu.cn/info/1094/11001.htm?wbnewsid=21001',
      category: '通知公告',
      date: '2026-09-04',
    ),
    const Notice(
      title: '2026-2027学年第一学期课程补选安排的通知',
      url: 'https://jwc.zjxu.edu.cn/info/1094/11002.htm?wbnewsid=21002',
      category: '通知公告',
      date: '2026-09-02',
    ),
    const Notice(
      title: '关于开展实验室安全竞赛活动的通知',
      url: 'https://jwc.zjxu.edu.cn/info/1094/11003.htm?wbnewsid=21003',
      category: '通知公告',
      date: '2026-08-30',
    ),
    const Notice(
      title: '图书馆数据库试用公告（2026年9月）',
      url: 'https://jwc.zjxu.edu.cn/info/1095/11004.htm?wbnewsid=21004',
      category: '通知公告',
      date: '2026-08-27',
    ),
    const Notice(
      title: '2026年暑期社会实践学分认定结果公示',
      url: 'https://jwc.zjxu.edu.cn/info/1094/11005.htm?wbnewsid=21005',
      category: '公示公告',
      date: '2026-08-25',
    ),
    const Notice(
      title: '校园网络升级维护公告',
      url: 'https://jwc.zjxu.edu.cn/info/1095/11006.htm?wbnewsid=21006',
      category: '通知公告',
      date: '2026-08-21',
    ),
  ];
  NoticeSyncStore.instance.debugInjectState(
    NoticeSyncSnapshot(
      snapshotIds: {for (final n in notices) n.id: DateTime(2026, 9, 5)},
      inbox: notices,
      unreadIds: unreadIds,
      pendingNotifyIds: const <String>{},
      notifiedIds: unreadIds,
      pendingBackfillPage: null,
      baselineBuilt: true,
      lastAttemptAt: DateTime(2026, 9, 5, 8),
      lastSuccessfulSyncAt: DateTime(2026, 9, 5, 8),
    ),
  );
  NoticeSyncStore.instance.debugReloadNoop = true;
}

/// 富状态首页种子：今天跨下午/晚间的课程（任意时间渲染都有"正在上课/下一节"）、
/// 明天上午考试（事件横幅）、校园卡/电费新鲜缓存（缓存命中，离线不触发网络与
/// 错误 Toast），开学日固定为今天保证恒为第 1 周。
Future<void> _seedRichHomeState() async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  final examDateText =
      '${tomorrow.year}-'
      '${tomorrow.month.toString().padLeft(2, '0')}-'
      '${tomorrow.day.toString().padLeft(2, '0')}';

  SharedPreferences.setMockInitialValues({
    'dorm_epay_area_id': 'area',
    'dorm_epay_building_id': 'building',
    'dorm_epay_floor_id': 'floor',
    'dorm_epay_room_id': 'room',
  });
  ZhengfangAuth.instance.debugSetSession(active: true, studentId: '2025000001');
  await CredentialStore.instance.saveZhengfangSession('2025000001');
  final academicEpoch = (await AuthSessionPersistence.instance.read(
    CredentialSessionDomain.academic,
  )).epoch;
  await SharedPreferencesPrivateCacheStore(ExamService.cacheKey).write(
    PrivateCacheEnvelope(
      owner: '2025000001',
      updatedAt: now,
      epoch: academicEpoch,
      payload: [
        {
          'kcmc': '微观经济学',
          'kssj': '($examDateText) 09:00-11:00',
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
  await SharedPreferencesPrivateCacheStore(GradesService.cacheKey).write(
    PrivateCacheEnvelope(
      owner: '2025000001',
      updatedAt: now,
      epoch: academicEpoch,
      payload: [
        {'kcmc': '高等数学 B', 'cj': '92', 'bfzcj': '92', 'jd': '4.0', 'xf': '4.5'},
        {'kcmc': '数据结构', 'cj': '88', 'bfzcj': '88', 'jd': '3.7', 'xf': '4.0'},
        {'kcmc': '大学英语', 'cj': '85', 'bfzcj': '85', 'jd': '3.5', 'xf': '3.0'},
      ],
    ),
  );
  await ExamService.instance.restoreCache();
  await GradesService.instance.restoreCache();

  UnifiedAuthService.instance.debugSetSession(active: true, account: 'casuser');
  await CredentialStore.instance.saveUnifiedAuthSession('casuser');
  final cardEpoch = (await AuthSessionPersistence.instance.read(
    CredentialSessionDomain.unified,
  )).epoch;
  await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
    PrivateCacheEnvelope(
      owner: 'casuser',
      updatedAt: now,
      epoch: cardEpoch,
      payload: 38.2,
    ),
  );
  await CampusCardService.instance.restoreBalance();
  DormElectricityService.instance.debugSetCachedElectricity(
    27.4,
    updatedAt: now,
  );
  await SemesterCalendar.instance.setSemesterStartDate(today);

  CourseEntry course(
    String name,
    int weekday,
    int start,
    int end,
    String room,
  ) => CourseEntry(
    courseName: name,
    teacherName: '王老师',
    weekday: weekday,
    startLesson: start,
    endLesson: end,
    weekRange: '1-20周',
    classroom: room,
    campus: '梁林校区',
    typeSymbol: '',
  );

  ScheduleService.instance.debugSetSnapshot(
    ScheduleCacheSnapshot(
      studentId: '2025000001',
      termContext: ScheduleTermContext.current(now),
      courses: [
        // 今天：跨下午与晚间，保证任意时间渲染都有"今天剩余课程"。
        course('数据结构', today.weekday, 9, 10, '教C-201'),
        course('大学英语', today.weekday, 11, 12, '外B-305'),
        course('体育俱乐部', today.weekday, 13, 13, '田径场'),
        // 明天第一节课（Hero 预告）。
        course('高等数学 B', tomorrow.weekday, 1, 2, '教B-102'),
        // 本周工作日摘要：周一 3 / 周二 2 / 周三 1 / 周四 0 / 周五 2。
        course('线性代数 B', 1, 1, 2, '铭德楼 240'),
        course('数据结构', 1, 6, 7, '教C-201'),
        course('大学英语', 1, 11, 12, '外B-305'),
        course('高等数学 B', 2, 3, 4, '教A-110'),
        course('毛泽东思想概论', 2, 8, 9, '铭德楼 118'),
        course('数据结构', 3, 1, 2, '教C-201'),
        course('大学物理', 5, 3, 4, '物理楼 201'),
        course('线性代数 B', 5, 6, 7, '铭德楼 240'),
      ],
      scheduleUpdatedAt: now,
      changeRulesUpdatedAt: now,
    ),
  );

  AppBootstrapController.instance.debugSetPhase(
    AppBootstrapPhase.localStateReady,
  );
}

/// 假期首页种子：开学日 = 今天 + 2 天（Hero「距离开学还有 2 天」），
/// 开学首日排 4 节课——预览截断为 3 条 + 「查看全部」；余额/电费新鲜
/// 缓存保证资产行有数值。
Future<void> _seedBreakHomeState() async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final semesterStart = today.add(const Duration(days: 2));

  SharedPreferences.setMockInitialValues({
    'dorm_epay_area_id': 'area',
    'dorm_epay_building_id': 'building',
    'dorm_epay_floor_id': 'floor',
    'dorm_epay_room_id': 'room',
  });

  UnifiedAuthService.instance.debugSetSession(active: true, account: 'casuser');
  await CredentialStore.instance.saveUnifiedAuthSession('casuser');
  final cardEpoch = (await AuthSessionPersistence.instance.read(
    CredentialSessionDomain.unified,
  )).epoch;
  await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
    PrivateCacheEnvelope(
      owner: 'casuser',
      updatedAt: now,
      epoch: cardEpoch,
      payload: 38.2,
    ),
  );
  await CampusCardService.instance.restoreBalance();
  DormElectricityService.instance.debugSetCachedElectricity(
    27.4,
    updatedAt: now,
  );
  await SemesterCalendar.instance.setSemesterStartDate(semesterStart);

  CourseEntry course(String name, int start, int end, String room) =>
      CourseEntry(
        courseName: name,
        teacherName: '王老师',
        weekday: semesterStart.weekday,
        startLesson: start,
        endLesson: end,
        // 开学日落在第 1 教学周，覆盖第 1-2 周即可。
        weekRange: '1-2周',
        classroom: room,
        campus: '梁林校区',
        typeSymbol: '',
      );

  ScheduleService.instance.debugSetSnapshot(
    ScheduleCacheSnapshot(
      studentId: '2025000001',
      termContext: ScheduleTermContext.current(now),
      courses: [
        course('高等数学 B', 1, 2, '教B-102'),
        course('大学英语', 3, 4, '外B-305'),
        course('数据结构', 6, 7, '教C-201'),
        course('大学物理', 8, 9, '物理楼 201'),
      ],
      scheduleUpdatedAt: now,
      changeRulesUpdatedAt: now,
    ),
  );

  AppBootstrapController.instance.debugSetPhase(
    AppBootstrapPhase.localStateReady,
  );
}

// ── 场景实现 ────────────────────────────────────────────────────────────────

Widget _sectionLabel(String text) => Padding(
  padding: const EdgeInsets.only(top: 20, bottom: 10),
  child: Text(
    text,
    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
  ),
);

/// 共用组件画廊：所有视觉重构应以这里渲染出的组件为唯一来源。
class _ComponentGallery extends StatelessWidget {
  const _ComponentGallery();

  @override
  Widget build(BuildContext context) {
    final searchController = TextEditingController();

    return Scaffold(
      appBar: AppAppBar(title: const Text('组件画廊')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        children: [
          _sectionLabel('AppCard · 实色'),
          AppCard(
            onTap: () {},
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '实色卡片（可点击）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'AppCard 默认形态：surface + 细描边 + squircle',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _sectionLabel('AppTileSurface · 质感瓦片（功能区同款）'),
          SizedBox(
            height: 76,
            child: AppTileSurface(
              onTap: () {},
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Center(
                widthFactor: 1,
                child: Row(
                  children: [
                    const AppIconBadge(
                      icon: Icons.calendar_month_rounded,
                      accentColor: Color(0xFF8B1A2D),
                      size: AppIconBadgeSize.small,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '整行瓦片 · rank0',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '平色卡面 + 细描边 + 柔影，统计行只读缓存',
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppTileSurface(
                  onTap: () {},
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const AppIconBadge(
                        icon: Icons.school_outlined,
                        accentColor: Color(0xFFD4AF37),
                        size: AppIconBadgeSize.small,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '半宽小瓦片',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppTileSurface(
                  onTap: () {},
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const AppIconBadge(
                        icon: Icons.account_balance_wallet_outlined,
                        accentColor: Color(0xFF1565C0),
                        size: AppIconBadgeSize.small,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '半宽小瓦片',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          _sectionLabel('GlassContainer · 三级材质'),
          GlassContainer(
            tier: GlassTier.card,
            blurred: true,
            padding: const EdgeInsets.all(16),
            child: const Text('card tier · 真实模糊（跟随全局模糊强度）'),
          ),
          const SizedBox(height: 12),
          GlassContainer(
            tier: GlassTier.nav,
            padding: const EdgeInsets.all(16),
            child: const Text('nav tier · sigma 24（每屏至多 1）'),
          ),
          const SizedBox(height: 12),
          GlassContainer(
            tier: GlassTier.overlay,
            padding: const EdgeInsets.all(16),
            child: const Text('overlay tier · sigma 30（弹层）'),
          ),
          _sectionLabel('AppIconBadge · 三档尺寸'),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              AppIconBadge(
                icon: Icons.calendar_month_rounded,
                accentColor: Color(0xFF8B1A2D),
                size: AppIconBadgeSize.small,
              ),
              AppIconBadge(
                icon: Icons.school_outlined,
                accentColor: Color(0xFFD4AF37),
                size: AppIconBadgeSize.medium,
              ),
              AppIconBadge(
                icon: Icons.account_balance_wallet_outlined,
                accentColor: Color(0xFF1565C0),
                size: AppIconBadgeSize.large,
              ),
            ],
          ),
          _sectionLabel('AppSearchField'),
          AppSearchField(
            controller: searchController,
            hintText: '搜索功能',
            onChanged: (_) {},
            onClear: () {},
          ),
          _sectionLabel('AppDropdown'),
          AppDropdown<String>(
            value: '2025-2026-1',
            items: const [
              AppDropdownItem(value: '2025-2026-1', label: '2025-2026 学年 第一学期'),
              AppDropdownItem(value: '2024-2025-2', label: '2024-2025 学年 第二学期'),
            ],
            onChanged: (_) {},
            expanded: true,
            prefixIcon: Icons.event_note_outlined,
          ),
          _sectionLabel('按钮与选择控件'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton(onPressed: () {}, child: const Text('主操作')),
              OutlinedButton(onPressed: () {}, child: const Text('次操作')),
              TextButton(onPressed: () {}, child: const Text('文字按钮')),
              const Chip(label: Text('标签')),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: true,
            onChanged: (_) {},
            title: const Text('开关控件'),
          ),
          _sectionLabel('未登录态 · AuthRequiredView'),
          AuthRequiredView(
            title: '未登录教务系统',
            message: '登录后即可查看成绩、课表与考试安排。',
            buttonLabel: '去登录',
            onAction: () {},
          ),
          _sectionLabel('AppEmptyView · 空状态'),
          const AppEmptyView(title: '今天没有课程', message: '休息一下，或去课表看看本周安排。'),
          _sectionLabel('AppErrorView · 错误状态'),
          AppErrorView(message: '网络连接超时，请检查网络后重试。', onRetry: () {}),
          _sectionLabel('GlassNavBar · 浮动 dock'),
          GlassNavBar(
            destinations: const [
              GlassNavBarDestination(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home_rounded,
                label: '首页',
              ),
              GlassNavBarDestination(
                icon: Icons.widgets_outlined,
                selectedIcon: Icons.widgets_rounded,
                label: '功能',
              ),
              GlassNavBarDestination(
                icon: Icons.person_outline,
                selectedIcon: Icons.person_rounded,
                label: '我的',
              ),
            ],
            currentIndex: 0,
            onDestinationSelected: (_) {},
          ),
        ],
      ),
    );
  }
}

/// 三级玻璃材质悬浮在彩色富背景之上，直观对比真实模糊差异。
///
/// 背景文字行按固定间距落位，保证每张玻璃卡后面都有文字行可被磨砂，
/// 不依赖滚动位置的巧合重叠。
class _GlassTiersBackdropScene extends StatelessWidget {
  const _GlassTiersBackdropScene();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: _ColorfulBackdrop()),
          Positioned(
            top: 150,
            left: 16,
            right: 16,
            child: Column(
              children: [
                GlassContainer(
                  tier: GlassTier.card,
                  blurred: true,
                  padding: const EdgeInsets.all(16),
                  child: const Text('card tier · blurred: true'),
                ),
                const SizedBox(height: 20),
                GlassContainer(
                  tier: GlassTier.card,
                  blurred: false,
                  padding: const EdgeInsets.all(16),
                  child: const Text('card tier · blurred: false（纯 tint）'),
                ),
                const SizedBox(height: 20),
                GlassContainer(
                  tier: GlassTier.nav,
                  padding: const EdgeInsets.all(16),
                  child: const Text('nav tier · sigma 24（每屏至多 1）'),
                ),
                const SizedBox(height: 20),
                GlassContainer(
                  tier: GlassTier.overlay,
                  padding: const EdgeInsets.all(16),
                  child: const Text('overlay tier · sigma 30（弹层）'),
                ),
              ],
            ),
          ),
          const Positioned(
            top: 24,
            left: 16,
            child: Text(
              '玻璃材质层级对比',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 高饱和渐变 + 固定间距文本行背景，行位与玻璃卡带（y≈150-500）对齐，
/// 让模糊效果一目了然；卡带下方保留锐利参照行。
class _ColorfulBackdrop extends StatelessWidget {
  const _ColorfulBackdrop();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF8B1A2D),
            Color(0xFFD4AF37),
            Color(0xFF1565C0),
            Color(0xFF2EA567),
          ],
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 176),
          for (var i = 0; i < 8; i++) ...[
            Text(
              '背景内容 $i · 背景内容 · 背景',
              style: TextStyle(
                fontSize: i.isEven ? 20 : 15,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 42),
          ],
        ],
      ),
    );
  }
}

/// 诊断场景：内容滚动到 AppAppBar 之下，验证毛玻璃是否真实生效。
class _AppBarScrollUnderScene extends StatelessWidget {
  const _AppBarScrollUnderScene();

  @override
  Widget build(BuildContext context) {
    final controller = ScrollController(initialScrollOffset: 260);
    return Scaffold(
      // 必须 extendBodyBehindAppBar：否则 body 从栏下开始，
      // 没有内容会滚到顶栏后面，模糊无从验证。
      extendBodyBehindAppBar: true,
      appBar: AppAppBar(title: const Text('滚动毛玻璃诊断')),
      body: ListView(
        controller: controller,
        children: [
          for (var i = 0; i < 40; i++)
            ListTile(
              title: Text('列表项 $i · 内容应当被顶栏毛玻璃模糊'),
              subtitle: const Text('滚动到顶栏之下的内容'),
            ),
        ],
      ),
    );
  }
}

/// 悬浮玻璃底栏 + extendBody 的 shell 观感。
class _NavShellScene extends StatelessWidget {
  const _NavShellScene();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 120),
        children: [
          for (var i = 0; i < 8; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppCard(
                onTap: () {},
                child: Text('内容卡片 $i · 内容可以滚动到玻璃底栏之下'),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: GlassNavBar(
          destinations: const [
            GlassNavBarDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              label: '主页',
            ),
            GlassNavBarDestination(
              icon: Icons.widgets_outlined,
              selectedIcon: Icons.widgets_rounded,
              label: '功能',
            ),
            GlassNavBarDestination(
              icon: Icons.person_outline,
              selectedIcon: Icons.person_rounded,
              label: '我的',
            ),
          ],
          currentIndex: 0,
          onDestinationSelected: (_) {},
        ),
      ),
    );
  }
}

/// 复刻 AppShell 的悬浮 dock 外壳（extendBody + SafeArea 底距 14），
/// 让首页公告开屏形态的 dock 遮挡关系在预览里如实可见。
class _HomeDockScene extends StatelessWidget {
  const _HomeDockScene();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: const HomePage(),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: GlassNavBar(
            destinations: const [
              GlassNavBarDestination(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
                label: '主页',
              ),
              GlassNavBarDestination(
                icon: Icons.widgets_outlined,
                selectedIcon: Icons.widgets,
                label: '功能',
              ),
              GlassNavBarDestination(
                icon: Icons.person_outline,
                selectedIcon: Icons.person,
                label: '我的',
              ),
            ],
            currentIndex: 0,
            onDestinationSelected: (_) {},
          ),
        ),
      ),
    );
  }
}
