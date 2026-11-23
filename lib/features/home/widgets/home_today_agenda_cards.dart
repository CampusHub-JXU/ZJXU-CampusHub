import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_surface_style.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import '../models/home_today_agenda.dart';

/// 首页「今天」板块下方的扩展聚合区（方案 C · Bento 紧凑双卡）：
/// 近期考试（未来 1–7 天）与二课日程（进行中 / 未来 7 天内已报名或已订阅活动）。
///
/// * **双卡并排模式**（考试与二课均非空）：`IntrinsicHeight + Row + Expanded` 等宽双卡；
/// * **单卡铺满模式**（仅考试或仅二课）：铺满整行展示清晰条目列表；
/// * 外框统一为 `AppRadius.card`（12dp）与 `AppTileSurface(blurred: false)`，
///   状态与倒计时标签统一为 `AppRadius.tag`（6dp），零胶囊、零 `BackdropFilter`。
class HomeTodayAgendaCards extends StatelessWidget {
  const HomeTodayAgendaCards({
    super.key,
    required this.agenda,
    required this.onOpenExam,
    required this.onOpenSecondClassroom,
  });

  final HomeTodayAgenda agenda;
  final VoidCallback onOpenExam;
  final VoidCallback onOpenSecondClassroom;

  @override
  Widget build(BuildContext context) {
    if (!agenda.hasExtras) return const SizedBox.shrink();

    final hasExams = agenda.upcomingExams.isNotEmpty;
    final hasActivities = agenda.upcomingActivities.isNotEmpty;

    if (hasExams && hasActivities) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _ExamBentoCard(
                exams: agenda.upcomingExams,
                onTap: onOpenExam,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _ActivityBentoCard(
                activities: agenda.upcomingActivities,
                onTap: onOpenSecondClassroom,
              ),
            ),
          ],
        ),
      );
    }

    if (hasExams) {
      return _SingleAgendaCard<HomeUpcomingExamItem>(
        title: '近期考试',
        actionLabel: '查看全部',
        actionSemanticsLabel: '查看全部近期考试',
        onActionTap: onOpenExam,
        items: agenda.upcomingExams,
        itemBuilder: (item) => _ExamAgendaRow(item: item, onTap: onOpenExam),
      );
    }

    return _SingleAgendaCard<HomeUpcomingActivityItem>(
      title: '二课日程',
      actionLabel: '全部活动',
      actionSemanticsLabel: '查看全部二课活动',
      onActionTap: onOpenSecondClassroom,
      items: agenda.upcomingActivities,
      itemBuilder: (item) =>
          _ActivityAgendaRow(item: item, onTap: onOpenSecondClassroom),
    );
  }
}

/// 并排 Bento 考试卡：展示首条考试核心信息，多条时底部补充紧凑摘要。
class _ExamBentoCard extends StatelessWidget {
  const _ExamBentoCard({required this.exams, required this.onTap});

  final List<HomeUpcomingExamItem> exams;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final first = exams.first;
    final accent = first.isUrgent ? cs.error : cs.primary;
    final badgeBg = accent.withValues(alpha: isDark ? 0.18 : 0.10);

    final extraCount = exams.length - 1;
    final footerSummary = extraCount > 0
        ? '另有 $extraCount 项 · ${exams[1].courseName}'
        : null;
    final semantics = extraCount > 0
        ? '近期考试，共${exams.length}项，最近：${first.courseName}，${first.dateLabel}，${first.timeRange}'
        : '近期考试，${first.courseName}，${first.dateLabel}，${first.timeRange}';

    return _AgendaBentoCard(
      title: '近期考试',
      count: exams.length,
      tagLabel: first.dateLabel,
      tagBackground: badgeBg,
      tagForeground: accent,
      tagTabular: true,
      timeText: first.timeRange,
      timeTabular: true,
      itemTitle: first.courseName,
      footerSummary: footerSummary,
      semanticsLabel: semantics,
      onTap: onTap,
    );
  }
}

/// 并排 Bento 二课卡：展示首条活动核心信息，多条时底部补充紧凑摘要。
class _ActivityBentoCard extends StatelessWidget {
  const _ActivityBentoCard({required this.activities, required this.onTap});

  final List<HomeUpcomingActivityItem> activities;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final first = activities.first;
    final (badgeLabel, badgeBg, badgeFg) = _activityBadgeColors(cs, first);

    final loc = first.locationText.trim();
    final timeOrLoc = first.isOngoing
        ? (loc.isEmpty ? '正在进行' : loc)
        : first.timeLabel;
    final extraCount = activities.length - 1;
    final footerSummary = extraCount > 0
        ? '另有 $extraCount 项 · ${activities[1].title}'
        : null;
    final semantics = extraCount > 0
        ? '二课日程，共${activities.length}项，最近：${first.title}，$badgeLabel，$timeOrLoc'
        : '二课日程，${first.title}，$badgeLabel，$timeOrLoc';

    return _AgendaBentoCard(
      title: '二课日程',
      count: activities.length,
      tagLabel: badgeLabel,
      tagBackground: badgeBg,
      tagForeground: badgeFg,
      tagTabular: false,
      timeText: timeOrLoc,
      timeTabular: !first.isOngoing,
      itemTitle: first.title,
      footerSummary: footerSummary,
      semanticsLabel: semantics,
      onTap: onTap,
    );
  }
}

/// 双卡并排模式的共用 Bento 卡片结构。
class _AgendaBentoCard extends StatelessWidget {
  const _AgendaBentoCard({
    required this.title,
    required this.count,
    required this.tagLabel,
    required this.tagBackground,
    required this.tagForeground,
    required this.tagTabular,
    required this.timeText,
    required this.timeTabular,
    required this.itemTitle,
    required this.footerSummary,
    required this.semanticsLabel,
    required this.onTap,
  });

  final String title;
  final int count;
  final String tagLabel;
  final Color tagBackground;
  final Color tagForeground;
  final bool tagTabular;
  final String timeText;
  final bool timeTabular;
  final String itemTitle;
  final String? footerSummary;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: AppHardTileShell(
        radius: AppRadius.card,
        child: AppTileSurface(
          blurred: false,
          borderRadius: AppRadius.cardBorder,
          onTap: onTap,
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.max,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.appText.group.copyWith(
                        color: secondaryTextColor,
                      ),
                    ),
                  ),
                  if (count > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$count项',
                      style: context.appText.tag.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        color: secondaryTextColor.withValues(alpha: 0.8),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: secondaryTextColor.withValues(alpha: 0.55),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _AgendaTag(
                    label: tagLabel,
                    backgroundColor: tagBackground,
                    foregroundColor: tagForeground,
                    tabular: tagTabular,
                    minWidth: 0,
                  ),
                  Text(
                    timeText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.appText.meta.copyWith(
                      fontSize: 12,
                      color: secondaryTextColor,
                      fontFeatures: timeTabular
                          ? const [FontFeature.tabularFigures()]
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                itemTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.appText.body.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: primaryTextColor,
                ),
              ),
              if (footerSummary != null) ...[
                const Spacer(),
                const SizedBox(height: 8),
                const _AgendaHairlineDivider(indent: 0),
                const SizedBox(height: 6),
                Text(
                  footerSummary!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.appText.tag.copyWith(
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                    color: secondaryTextColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 单卡铺满模式：整行宽度展示单个分类的完整日程条目列表。
class _SingleAgendaCard<T> extends StatelessWidget {
  const _SingleAgendaCard({
    required this.title,
    required this.actionLabel,
    required this.actionSemanticsLabel,
    required this.onActionTap,
    required this.items,
    required this.itemBuilder,
  });

  final String title;
  final String actionLabel;
  final String actionSemanticsLabel;
  final VoidCallback onActionTap;
  final List<T> items;
  final Widget Function(T item) itemBuilder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    return AppHardTileShell(
      radius: AppRadius.card,
      child: AppTileSurface(
        blurred: false,
        borderRadius: AppRadius.cardBorder,
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              label: actionSemanticsLabel,
              excludeSemantics: true,
              onTap: onActionTap,
              child: InkWell(
                onTap: onActionTap,
                excludeFromSemantics: true,
                borderRadius: BorderRadius.circular(AppRadius.card - 4),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        title,
                        style: context.appText.group.copyWith(
                          color: secondaryTextColor,
                        ),
                      ),
                      if (items.length > 1) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${items.length}项',
                          style: context.appText.tag.copyWith(
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                            color: secondaryTextColor.withValues(alpha: 0.8),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        actionLabel,
                        style: context.appText.meta.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: cs.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const _AgendaHairlineDivider(indent: 10),
            for (final (index, item) in items.indexed) ...[
              if (index > 0) const _AgendaHairlineDivider(indent: 10),
              itemBuilder(item),
            ],
          ],
        ),
      ),
    );
  }
}

(String label, Color bg, Color fg) _activityBadgeColors(
  ColorScheme cs,
  HomeUpcomingActivityItem item,
) {
  return switch (item.isOngoing) {
    true => ('进行中', cs.primary, cs.onPrimary),
    false when item.badgeLabel == '已报名' => (
      item.badgeLabel,
      cs.secondaryContainer,
      cs.onSecondaryContainer,
    ),
    false => (item.badgeLabel, cs.surfaceContainerHighest, cs.onSurfaceVariant),
  };
}

/// 单卡铺满模式下的近期考试行。
class _ExamAgendaRow extends StatelessWidget {
  const _ExamAgendaRow({required this.item, required this.onTap});

  final HomeUpcomingExamItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final accent = item.isUrgent ? cs.error : cs.primary;
    final badgeBg = accent.withValues(alpha: isDark ? 0.18 : 0.10);

    final loc = item.locationText.trim();
    final subtitle = loc.isEmpty ? item.timeRange : '${item.timeRange} · $loc';
    final semantics = loc.isEmpty
        ? '${item.courseName}，${item.dateLabel}，${item.timeRange}'
        : '${item.courseName}，${item.dateLabel}，${item.timeRange}，$loc';

    return _AgendaRowShell(
      leading: _AgendaTag(
        label: item.dateLabel,
        backgroundColor: badgeBg,
        foregroundColor: accent,
        tabular: true,
      ),
      title: item.courseName,
      subtitle: subtitle,
      subtitleTabular: true,
      semanticsLabel: semantics,
      onTap: onTap,
    );
  }
}

/// 单卡铺满模式下的二课日程行。
class _ActivityAgendaRow extends StatelessWidget {
  const _ActivityAgendaRow({required this.item, required this.onTap});

  final HomeUpcomingActivityItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (badgeLabel, badgeBg, badgeFg) = _activityBadgeColors(cs, item);

    final loc = item.locationText.trim();
    final subtitle = item.isOngoing
        ? (loc.isEmpty ? '正在进行' : loc)
        : (loc.isEmpty ? item.timeLabel : '${item.timeLabel} · $loc');
    final semantics = '${item.title}，$badgeLabel，$subtitle';

    return _AgendaRowShell(
      leading: _AgendaTag(
        label: badgeLabel,
        backgroundColor: badgeBg,
        foregroundColor: badgeFg,
      ),
      title: item.title,
      subtitle: subtitle,
      subtitleTabular: !item.isOngoing,
      semanticsLabel: semantics,
      onTap: onTap,
    );
  }
}

/// 单卡铺满模式下的紧凑条目行：6dp 方标前置 + 两行主次信息 + 右箭头。
class _AgendaRowShell extends StatelessWidget {
  const _AgendaRowShell({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.semanticsLabel,
    required this.onTap,
    this.subtitleTabular = false,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final String semanticsLabel;
  final VoidCallback onTap;
  final bool subtitleTabular;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    final subtitleStyle = context.appText.meta.copyWith(
      color: secondaryTextColor,
      fontFeatures: subtitleTabular
          ? const [FontFeature.tabularFigures()]
          : null,
    );

    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(AppRadius.card - 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: context.appText.rowTitle.copyWith(
                        color: primaryTextColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: subtitleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: secondaryTextColor.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 6dp 圆角方标（非胶囊）。
class _AgendaTag extends StatelessWidget {
  const _AgendaTag({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    this.tabular = false,
    this.minWidth = 50,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final bool tabular;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final textStyle = context.appText.tag.copyWith(
      color: foregroundColor,
      fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: backgroundColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.tag),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: textStyle,
          ),
        ),
      ),
    );
  }
}

/// 卡片内行间细淡分隔线。
class _AgendaHairlineDivider extends StatelessWidget {
  const _AgendaHairlineDivider({this.indent = 12});

  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Divider(
      height: 0.5,
      thickness: 0.5,
      indent: indent,
      endIndent: indent,
      color: theme.colorScheme.outlineVariant.withValues(
        alpha: isDark ? 0.28 : 0.45,
      ),
    );
  }
}
