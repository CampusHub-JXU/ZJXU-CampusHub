import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:jxu_campus_hub/core/theme/app_design_tokens.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_primary_status_hero.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';

void main() {
  setUp(AppThemeController.instance.debugReset);
  tearDown(AppThemeController.instance.debugReset);

  const sampleHero = HomeHeroPresentation(
    kind: HomeHeroKind.noCourseToday,
    headline: '今天没有课',
    timeText: '好好休息',
  );

  Future<void> pumpHero(
    WidgetTester tester, {
    ThemeData? theme,
    String envDateText = '9月11日 周五',
    String envStatusText = '第 3 周',
    bool canShowUpdateAction = false,
    int unreadNoticeCount = 0,
    VoidCallback? onNotificationTap,
    VoidCallback? onUpdateTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme:
            theme ??
            AppThemeBuilder.light(AppThemeController.defaultCustomSeedColor),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(AppSpacing.pageMargin),
            child: HomePrimaryStatusHero(
              hero: sampleHero,
              envDateText: envDateText,
              envStatusText: envStatusText,
              canShowUpdateAction: canShowUpdateAction,
              unreadNoticeCount: unreadNoticeCount,
              onOpenSchedule: () {},
              onNotificationTap: onNotificationTap ?? () {},
              onUpdateTap: onUpdateTap,
            ),
          ),
        ),
      ),
    );
  }

  /// 环境行的两个控件态玻璃胶囊（chip 圆角）。
  List<GlassContainer> findEnvGlassPills(WidgetTester tester) {
    return tester
        .widgetList<GlassContainer>(find.byType(GlassContainer))
        .where((g) => g.borderRadius == AppRadius.chipBorder)
        .toList();
  }

  /// Hero 主体应无玻璃卡片（card 圆角的 GlassContainer）——无框纯排版。
  List<GlassContainer> findHeroGlassCards(WidgetTester tester) {
    return tester
        .widgetList<GlassContainer>(find.byType(GlassContainer))
        .where((g) => g.borderRadius == AppRadius.cardBorder)
        .toList();
  }

  testWidgets('无更新时环境行渲染两个等高玻璃胶囊，Hero 主体为无框排版', (tester) async {
    var notificationTapped = 0;
    await pumpHero(
      tester,
      canShowUpdateAction: false,
      unreadNoticeCount: 3,
      onNotificationTap: () => notificationTapped++,
    );

    final pills = findEnvGlassPills(tester);
    expect(pills, hasLength(2));
    expect(findHeroGlassCards(tester), isEmpty);

    final leftBox = find.byWidget(pills[0]);
    final rightBox = find.byWidget(pills[1]);
    expect(tester.getSize(leftBox).height, tester.getSize(rightBox).height);

    // 单个通知铃胶囊内只有 1 个 IconButton，且自身透明坐在玻璃面上。
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isTrue);

    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pump();
    expect(notificationTapped, 1);
  });

  testWidgets('有更新时更新按钮与通知铃融并入同一玻璃胶囊并对齐高度', (tester) async {
    var updateTapped = 0;
    var notificationTapped = 0;
    await pumpHero(
      tester,
      canShowUpdateAction: true,
      unreadNoticeCount: 0,
      onUpdateTap: () => updateTapped++,
      onNotificationTap: () => notificationTapped++,
    );

    // 左侧日期胶囊 + 右侧合并动作胶囊，共 2 个玻璃胶囊（不拆成 3 个独立胶囊）。
    final pills = findEnvGlassPills(tester);
    expect(pills, hasLength(2));

    final leftBox = find.byWidget(pills[0]);
    final rightBox = find.byWidget(pills[1]);
    expect(tester.getSize(leftBox).height, tester.getSize(rightBox).height);

    expect(
      find.descendant(of: rightBox, matching: find.byType(IconButton)),
      findsNWidgets(2),
    );
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isFalse);

    await tester.tap(find.byIcon(Icons.system_update_outlined));
    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pump();
    expect(updateTapped, 1);
    expect(notificationTapped, 1);
  });

  testWidgets('onUpdateTap 为空时即使 canShowUpdateAction 为真也不合并更新按钮', (
    tester,
  ) async {
    await pumpHero(tester, canShowUpdateAction: true, onUpdateTap: null);

    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byIcon(Icons.system_update_outlined), findsNothing);
  });

  testWidgets('浅色/深色与壁纸强制文字色模式下玻璃面明暗极性跟随适配', (tester) async {
    final lightTheme = AppThemeBuilder.light(
      AppThemeController.defaultCustomSeedColor,
    );
    final darkTheme = AppThemeBuilder.dark(
      AppThemeController.defaultCustomSeedColor,
    );

    // surface：玻璃面（两个环境胶囊）应呈现的明暗；
    // system 随主题，强制文字色模式跨极性时翻转。
    final cases =
        <({ThemeData theme, HomeTextColorMode mode, Brightness surface})>[
          (
            theme: lightTheme,
            mode: HomeTextColorMode.system,
            surface: Brightness.light,
          ),
          (
            theme: darkTheme,
            mode: HomeTextColorMode.system,
            surface: Brightness.dark,
          ),
          (
            theme: lightTheme,
            mode: HomeTextColorMode.dark,
            surface: Brightness.light,
          ),
          (
            theme: darkTheme,
            mode: HomeTextColorMode.dark,
            surface: Brightness.light,
          ),
          (
            theme: darkTheme,
            mode: HomeTextColorMode.light,
            surface: Brightness.dark,
          ),
          (
            theme: lightTheme,
            mode: HomeTextColorMode.light,
            surface: Brightness.dark,
          ),
        ];

    for (final c in cases) {
      AppThemeController.instance.updateHomeTextColorMode(c.mode);
      await pumpHero(
        tester,
        theme: c.theme,
        canShowUpdateAction: true,
        onUpdateTap: () {},
      );

      // 仅 2 个环境胶囊是玻璃面（Hero 主体无框），全部存在且亮度符合预期。
      final surfaces = tester
          .widgetList<GlassContainer>(find.byType(GlassContainer))
          .toList();
      expect(surfaces, hasLength(2));
      for (final surface in surfaces) {
        final element = tester.element(find.byWidget(surface));
        expect(Theme.of(element).brightness, c.surface);
      }
    }
  });

  testWidgets('超长周次日期文案在窄屏下省略不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHero(
      tester,
      envStatusText: '第 18 周 超级无敌长学期状态标签',
      envDateText: '12月31日 星期四 额外补充文本',
      canShowUpdateAction: true,
      onUpdateTap: () {},
    );

    expect(tester.takeException(), isNull);
  });
}
