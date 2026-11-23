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

  testWidgets('无更新时环境行与 Hero 主体均为无框排版，保留未读数字角标与 48dp 点击范围', (tester) async {
    var notificationTapped = 0;
    await pumpHero(
      tester,
      canShowUpdateAction: false,
      unreadNoticeCount: 3,
      onNotificationTap: () => notificationTapped++,
    );

    expect(find.byType(GlassContainer), findsNothing);
    expect(find.textContaining('第 3 周'), findsOneWidget);
    expect(find.textContaining('9月11日 周五'), findsOneWidget);

    final notificationFinder = find.byType(IconButton);
    expect(notificationFinder, findsOneWidget);
    final buttonSize = tester.getSize(notificationFinder);
    expect(buttonSize.width, greaterThanOrEqualTo(48));
    expect(buttonSize.height, greaterThanOrEqualTo(48));

    expect(find.text('3'), findsOneWidget);
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isTrue);

    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pump();
    expect(notificationTapped, 1);
  });

  testWidgets('有更新时展示更新红点按钮与通知铃，均无毛玻璃底且保持 48dp 点击范围', (tester) async {
    var updateTapped = 0;
    var notificationTapped = 0;
    await pumpHero(
      tester,
      canShowUpdateAction: true,
      unreadNoticeCount: 0,
      onUpdateTap: () => updateTapped++,
      onNotificationTap: () => notificationTapped++,
    );

    expect(find.byType(GlassContainer), findsNothing);

    final buttons = find.byType(IconButton);
    expect(buttons, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      final size = tester.getSize(buttons.at(i));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    final updateButton = find.ancestor(
      of: find.byIcon(Icons.system_update_outlined),
      matching: find.byType(IconButton),
    );
    expect(
      find.descendant(
        of: updateButton,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).shape == BoxShape.circle,
        ),
      ),
      findsOneWidget,
    );

    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isFalse);

    await tester.tap(find.byIcon(Icons.system_update_outlined));
    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pump();
    expect(updateTapped, 1);
    expect(notificationTapped, 1);
  });

  testWidgets('onUpdateTap 为空时即使 canShowUpdateAction 为真也不显示更新按钮', (
    tester,
  ) async {
    await pumpHero(tester, canShowUpdateAction: true, onUpdateTap: null);

    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byIcon(Icons.system_update_outlined), findsNothing);
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
