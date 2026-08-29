import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_page.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';

import 'package:jxu_campus_hub/features/home/home_page.dart';
import 'package:jxu_campus_hub/features/my/my_page.dart';

import 'package:jxu_campus_hub/features/settings/personalization_page.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';
import 'package:jxu_campus_hub/features/settings/theme_settings_page.dart';
import 'package:jxu_campus_hub/shared/widgets/app_app_bar.dart';
import 'package:jxu_campus_hub/shared/widgets/app_card.dart';
import 'package:jxu_campus_hub/shared/widgets/app_icon_badge.dart';
import 'package:jxu_campus_hub/shared/widgets/app_search_field.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_nav_bar.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_model.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';
import 'package:jxu_campus_hub/shared/widgets/ship_card.dart';

import '../helpers/test_setup.dart';
import '../helpers/preview_support.dart';

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
    await pumpPreviewScene(tester, (_) => _ComponentGallery());
    await expectPreviewGolden(tester, 'gallery_light');
  });

  previewTest('gallery_dark', (tester) async {
    await pumpPreviewScene(
      tester,
      (_) => _ComponentGallery(),
      brightness: Brightness.dark,
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

  previewTest('page_my_light', (tester) async {
    await renderPage(tester, 'page_my_light', const MyPage());
  });

  previewTest('page_settings_light', (tester) async {
    await renderPage(tester, 'page_settings_light', const SettingsPage());
  });

  previewTest('page_personalization_light', (tester) async {
    await renderPage(
      tester,
      'page_personalization_light',
      const PersonalizationPage(),
    );
  });

  previewTest('page_theme_settings_light', (tester) async {
    await renderPage(
      tester,
      'page_theme_settings_light',
      const ThemeSettingsPage(),
    );
  });

  // 说明：GradesPage / SchedulePage 在离线场景下会遗留网络重试 Timer，
  // 触发 flutter_test 的 pending-timer 断言，不适合放进无登录预览；
  // 它们的未登录态与 campus_card / AuthRequiredView 一致，画廊已覆盖。

  previewTest('page_campus_card_light', (tester) async {
    await renderPage(tester, 'page_campus_card_light', const CampusCardPage());
  });
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
    'dorm_community_id': 'community',
    'dorm_building_id': 'building',
    'dorm_floor_id': 'floor',
    'dorm_room_id': 'room',
    'exam_cached_data': jsonEncode([
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
    ]),
    'grades_cached_data': jsonEncode([
      {
        'kcmc': '高等数学 B',
        'cj': '92',
        'bfzcj': '92',
        'jd': '4.0',
        'xf': '4.5',
      },
      {'kcmc': '数据结构', 'cj': '88', 'bfzcj': '88', 'jd': '3.7', 'xf': '4.0'},
      {'kcmc': '大学英语', 'cj': '85', 'bfzcj': '85', 'jd': '3.5', 'xf': '3.0'},
    ]),
    // restoreCache 要求 json 与时间戳同时存在才恢复。
    'grades_cached_at': now.millisecondsSinceEpoch,
  });
  await ExamService.instance.restoreCache();
  await GradesService.instance.restoreCache();

  CampusCardService.instance.debugSetCachedBalance(38.2, updatedAt: now);
  DormElectricityService.instance.debugSetCachedElectricity(
    27.4,
    updatedAt: now,
  );
  await SemesterCalendar.instance.setSemesterStartDate(today);

  CourseEntry course(String name, int weekday, int start, int end, String room) =>
      CourseEntry(
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
    final cs = Theme.of(context).colorScheme;
    final searchController = TextEditingController();

    return Scaffold(
      appBar: AppAppBar(title: const Text('组件画廊')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        children: [
          _sectionLabel('AppCard · 实色 / 玻璃 tint'),
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
                  'AppCard 默认形态：surface + 受光描边 + squircle',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const AppCard(
            glassEnabled: true,
            child: Text('玻璃 tint 卡片（无 BackdropFilter）'),
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
          _sectionLabel('ShipCard · 品牌渐变卡'),
          ShipCard(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [cs.primary, cs.primary.withValues(alpha: 0.75)],
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('校园卡余额', style: TextStyle(color: Colors.white)),
                SizedBox(height: 8),
                Text(
                  '¥ 38.20',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
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
