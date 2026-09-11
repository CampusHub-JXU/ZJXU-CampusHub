import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import 'models/home_presentation.dart';
import 'widgets/home_asset_strip.dart';
import 'widgets/home_event_banner.dart';
import 'widgets/home_primary_status_hero.dart';
import 'widgets/home_today_section.dart';

/// 首页展示层场景（PRD 0.7.0 §17）：真实 Home Widget 组合的可复用渲染单元。
///
/// 线上首页与外观预览共用它，避免预览另画一套「白色方块模拟首页」。预览通过
/// [scaleToFit] 把真实布局等比缩放到预览框，保证所见即所得。
///
/// 交互回调在外观预览下是空实现；线上首页由 `HomePage` 传入真实回调或在
/// Phase C 迁移到本场景。
class HomeSurfaceScene extends StatelessWidget {
  const HomeSurfaceScene({
    super.key,
    required this.presentation,
    this.designWidth = 390,
    this.scaleToFit = true,
    this.envDateText = '9月11日 周五',
  });

  final HomePresentation presentation;

  /// 缩放基准宽度（真实手机逻辑宽度），仅在 [scaleToFit] 时生效。
  final double designWidth;

  /// 是否把整屏等比缩放到父约束（预览用）；线上首页传 false。
  final bool scaleToFit;

  final String envDateText;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.xl,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomePrimaryStatusHero(
            hero: presentation.hero,
            envDateText: envDateText,
            envStatusText: presentation.weekLabel,
            onOpenSchedule: () {},
            onNotificationTap: () {},
            onUpdateTap: () {},
          ),
          if (presentation.alert != null) ...[
            const SizedBox(height: AppSpacing.md),
            HomeEventBanner(alert: presentation.alert!, onTap: () {}),
          ],
          const SizedBox(height: AppSpacing.md),
          HomeTodaySection(today: presentation.today, onOpenSchedule: () {}),
          const SizedBox(height: AppSpacing.md),
          HomeAssetStrip(
            status: presentation.status,
            onCampusCardTap: () {},
            onElectricityTap: () {},
          ),
        ],
      ),
    );

    if (!scaleToFit) return content;
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(width: designWidth, child: content),
    );
  }
}
