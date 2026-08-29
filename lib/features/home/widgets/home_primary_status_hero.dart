import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../models/home_presentation.dart';

/// Primary Status Hero：首页唯一的最强视觉焦点（无框纯排版）。
///
/// 顶部环境行「日期 · 嘉兴大学 · 周次」+ 通知铃 / 更新入口；
/// 主体按 kicker → 大字 → 时间 → 地点元信息 → 「查看课表」的
/// 纯文字层级直接坐在页面背景上，靠 typography + spacing 建立层级，
/// 不使用任何卡片容器 / 玻璃 / 底纹。文字颜色统一走
/// [AppThemeController] 的 system 透传路径，兼容自定义背景图模式。
class HomePrimaryStatusHero extends StatelessWidget {
  const HomePrimaryStatusHero({
    super.key,
    required this.hero,
    required this.envDateText,
    required this.envStatusText,
    this.canShowUpdateAction = false,
    required this.onOpenSchedule,
    required this.onNotificationTap,
    required this.onUpdateTap,
  });

  final HomeHeroPresentation hero;

  /// 环境行日期文案，如「8月29日 周六」。
  final String envDateText;

  /// 环境行状态文案，如「第 3 周」/「未开学」/「假期中」。
  final String envStatusText;
  final bool canShowUpdateAction;

  /// 打开课表回调；仅课程类 Hero 显示「查看课表」入口，
  /// 其余 kind 传 null 且不渲染该入口。
  final VoidCallback? onOpenSchedule;
  final VoidCallback onNotificationTap;
  final VoidCallback? onUpdateTap;

  /// 仅这两类 Hero 展示课程大字与「查看课表」入口。
  bool get _isCourseKind =>
      hero.kind == HomeHeroKind.currentCourse ||
      hero.kind == HomeHeroKind.nextCourseToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    // kicker / 「查看课表」强调色：system 模式透传主题酒红，
    // 强制文字色模式（自定义背景图）下跟随可读文字色。
    final accentColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.primary,
    );
    final kickerColor = hero.kind == HomeHeroKind.examSoon
        ? AppThemeController.instance.resolveHomeTextColor(context, cs.error)
        : accentColor;
    final kickerText = switch (hero.kind) {
      HomeHeroKind.currentCourse => '正在上课',
      HomeHeroKind.nextCourseToday => '下一节课',
      HomeHeroKind.examSoon => '考试临近',
      HomeHeroKind.beforeSemester => '未开学',
      HomeHeroKind.semesterOver => '本学期已结束',
      HomeHeroKind.noCourseToday => '今天',
      HomeHeroKind.loggedOut => '未登录',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildEnvRow(context, primaryTextColor, secondaryTextColor),
        // 环境行到 kicker 之间的呼吸空间。
        const SizedBox(height: 56),
        Text(
          kickerText,
          style: textTheme.labelMedium!.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: kickerColor,
          ),
        ),
        const SizedBox(height: 8),
        if (_isCourseKind)
          _buildCourseHero(
            context,
            accentColor: accentColor,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          )
        else
          _buildStatusHero(
            context,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
      ],
    );
  }

  /// 顶部环境行：左「日期 · 嘉兴大学 · 周次」，右更新角标 + 通知铃。
  Widget _buildEnvRow(
    BuildContext context,
    Color primaryTextColor,
    Color secondaryTextColor,
  ) {
    final cs = Theme.of(context).colorScheme;
    final envStyle = Theme.of(context).textTheme.titleSmall!;
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: envDateText,
                  style: envStyle.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: secondaryTextColor,
                  ),
                ),
                TextSpan(
                  text: ' · 嘉兴大学 · ',
                  style: envStyle.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: secondaryTextColor,
                  ),
                ),
                TextSpan(
                  text: envStatusText,
                  style: envStyle.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: secondaryTextColor,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (canShowUpdateAction && onUpdateTap != null) ...[
          const SizedBox(width: 12),
          _buildUpdateAction(cs, primaryTextColor),
        ],
        const SizedBox(width: 12),
        IconButton(
          icon: Icon(
            Icons.notifications_outlined,
            color: primaryTextColor,
            size: 22,
          ),
          onPressed: onNotificationTap,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: '通知中心',
        ),
      ],
    );
  }

  Widget _buildUpdateAction(ColorScheme cs, Color iconColor) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: Icon(Icons.system_update_outlined, color: iconColor, size: 22),
          onPressed: onUpdateTap,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: '发现新版本',
        ),
        Positioned(
          right: -1,
          top: -1,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: cs.error,
              shape: BoxShape.circle,
              border: Border.all(color: cs.onError, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }

  /// 课程类 Hero（正在上课 / 下一节课）：
  /// 课程名 30sp 全屏最强视觉 → 时间 → 地点/节次 → 查看课表。
  /// 课程信息主体整体可点跳转课表（课表双入口：hero 主体 + 功能区瓦片）。
  Widget _buildCourseHero(
    BuildContext context, {
    required Color accentColor,
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final textTheme = Theme.of(context).textTheme;
    // 「下一节课」的倒计时大字（如「42 分钟后上课」）并入时间行，避免信息丢失。
    final timeLine =
        hero.kind == HomeHeroKind.nextCourseToday && hero.headline.isNotEmpty
        ? '${hero.timeText} · ${hero.headline}'
        : hero.timeText;
    final courseInfo = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hero.courseName ?? hero.headline,
          style: textTheme.headlineMedium!.copyWith(
            fontSize: 30,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: primaryTextColor,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (timeLine != null && timeLine.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            timeLine,
            style: textTheme.titleMedium!.copyWith(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: primaryTextColor,
            ),
          ),
        ],
        if (hero.locationText != null || hero.lessonText != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (hero.locationText != null) ...[
                Icon(
                  Icons.location_on_outlined,
                  size: 14,
                  color: secondaryTextColor,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    hero.locationText!,
                    style: textTheme.bodyMedium!.copyWith(
                      fontSize: 14,
                      color: secondaryTextColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (hero.lessonText != null) ...[
                if (hero.locationText != null) const SizedBox(width: 12),
                Icon(
                  Icons.schedule_outlined,
                  size: 14,
                  color: secondaryTextColor,
                ),
                const SizedBox(width: 4),
                Text(
                  hero.lessonText!,
                  style: textTheme.bodyMedium!.copyWith(
                    fontSize: 14,
                    color: secondaryTextColor,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onOpenSchedule != null)
          Semantics(
            button: true,
            label: '查看课表 ${hero.courseName ?? ''}',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onOpenSchedule,
              child: courseInfo,
            ),
          )
        else
          courseInfo,
        if (onOpenSchedule != null) ...[
          const SizedBox(height: 6),
          Semantics(
            button: true,
            label: '查看课表 ${hero.courseName ?? ''}',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onOpenSchedule,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '查看课表',
                      style: textTheme.titleSmall!.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: accentColor,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 16, color: accentColor),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 非课程类 Hero：headline 作大字，时间 / 课程名 / 地点作为副文案，
  /// 确保原有信息一项不丢。
  Widget _buildStatusHero(
    BuildContext context, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hero.headline,
          style: textTheme.headlineSmall!.copyWith(
            fontSize: 25,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: primaryTextColor,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (hero.timeText != null) ...[
          const SizedBox(height: 6),
          Text(
            hero.timeText!,
            style: textTheme.bodyMedium!.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: secondaryTextColor,
            ),
          ),
        ],
        if (hero.courseName != null) ...[
          const SizedBox(height: 4),
          Text(
            hero.courseName!,
            style: textTheme.bodyMedium!.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: secondaryTextColor,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (hero.locationText != null || hero.lessonText != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              if (hero.locationText != null) ...[
                Icon(
                  Icons.location_on_outlined,
                  size: 14,
                  color: secondaryTextColor,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    hero.locationText!,
                    style: textTheme.bodyMedium!.copyWith(
                      fontSize: 14,
                      color: secondaryTextColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (hero.lessonText != null) ...[
                if (hero.locationText != null) const SizedBox(width: 12),
                Icon(
                  Icons.schedule_outlined,
                  size: 14,
                  color: secondaryTextColor,
                ),
                const SizedBox(width: 4),
                Text(
                  hero.lessonText!,
                  style: textTheme.bodyMedium!.copyWith(
                    fontSize: 14,
                    color: secondaryTextColor,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
