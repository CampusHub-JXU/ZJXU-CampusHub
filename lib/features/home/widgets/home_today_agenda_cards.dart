import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_surface_style.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import '../models/home_today_agenda.dart';

/// 首页「今日」板块下方的扩展聚合卡片：近期考试（未来 1–7 天）与
/// 二课日程（进行中 / 未来 7 天内已报名或已订阅活动）。
///
/// 视觉上承接 `HomeTodaySection` 的轻量化语言：小节头 + `AppTileSurface`
/// （显式关闭模糊，零 `BackdropFilter`）+ 细淡行间分隔线；无内容时整块折叠。
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasExams)
          _AgendaSection<HomeUpcomingExamItem>(
            title: '近期考试',
            actionLabel: '查看全部',
            actionSemanticsLabel: '查看全部近期考试',
            onActionTap: onOpenExam,
            items: agenda.upcomingExams,
            itemBuilder: (item) =>
                _ExamAgendaRow(item: item, onTap: onOpenExam),
          ),
        if (hasExams && hasActivities) const SizedBox(height: AppSpacing.lg),
        if (hasActivities)
          _AgendaSection<HomeUpcomingActivityItem>(
            title: '二课日程',
            actionLabel: '全部活动',
            actionSemanticsLabel: '查看全部二课活动',
            onActionTap: onOpenSecondClassroom,
            items: agenda.upcomingActivities,
            itemBuilder: (item) =>
                _ActivityAgendaRow(item: item, onTap: onOpenSecondClassroom),
          ),
      ],
    );
  }
}

/// 带轻量小节头与平色瓦片容器的通用日程区块。
class _AgendaSection<T> extends StatelessWidget {
  const _AgendaSection({
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _AgendaSectionHeader(
          title: title,
          actionLabel: actionLabel,
          actionSemanticsLabel: actionSemanticsLabel,
          onActionTap: onActionTap,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppHardTileShell(
          radius: AppRadius.tile,
          child: AppTileSurface(
            blurred: false,
            borderRadius: AppRadius.tileBorder,
            // 4dp 外框内边距 + 12dp 行内边距 = 16dp 视觉对齐（AppSpacing.cardPadding），
            // 同时让行级 InkWell 的 r=16 圆角与外层 r=20 squircle 保持同心。
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (index, item) in items.indexed) ...[
                  if (index > 0) const _AgendaHairlineDivider(),
                  itemBuilder(item),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 轻量小节头：左「分组标」，右「动作 ›」。
class _AgendaSectionHeader extends StatelessWidget {
  const _AgendaSectionHeader({
    required this.title,
    required this.actionLabel,
    required this.actionSemanticsLabel,
    required this.onActionTap,
  });

  final String title;
  final String actionLabel;
  final String actionSemanticsLabel;
  final VoidCallback onActionTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(title, style: context.appText.label),
          ),
        ),
        const Spacer(),
        Semantics(
          button: true,
          label: actionSemanticsLabel,
          excludeSemantics: true,
          onTap: onActionTap,
          child: InkWell(
            onTap: onActionTap,
            excludeFromSemantics: true,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
      ],
    );
  }
}

/// 近期考试单行：左侧倒计时胶囊 + 课程名 + 时间/地点副行。
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
      leading: _AgendaPill(
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

/// 二课日程单行：左侧状态/来源胶囊 + 活动标题 + 时间/地点副行。
class _ActivityAgendaRow extends StatelessWidget {
  const _ActivityAgendaRow({required this.item, required this.onTap});

  final HomeUpcomingActivityItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (badgeLabel, badgeBg, badgeFg) = switch (item.isOngoing) {
      true => ('进行中', cs.primary, cs.onPrimary),
      false when item.badgeLabel == '已报名' => (
        item.badgeLabel,
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      false => (
        item.badgeLabel,
        cs.surfaceContainerHighest,
        cs.onSurfaceVariant,
      ),
    };

    final loc = item.locationText.trim();
    final subtitle = item.isOngoing
        ? (loc.isEmpty ? '正在进行' : loc)
        : (loc.isEmpty ? item.timeLabel : '${item.timeLabel} · $loc');
    final semantics = '${item.title}，$badgeLabel，$subtitle';

    return _AgendaRowShell(
      leading: _AgendaPill(
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

/// 卡片内通用紧凑行：胶囊前置 + 两行主次信息 + 轻量右箭头。
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
    final subtitleStyle = subtitleTabular
        ? context.appText.meta.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          )
        : context.appText.meta;

    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(AppRadius.tile - 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: context.appText.rowTitle,
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
                color: cs.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 左侧最小等宽胶囊标签：常规缩放下保持标题列竖直对齐，大字号下随文本自然撑开。
class _AgendaPill extends StatelessWidget {
  const _AgendaPill({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    this.tabular = false,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final bool tabular;

  @override
  Widget build(BuildContext context) {
    final textStyle = context.appText.tag.copyWith(
      color: foregroundColor,
      fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 52),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: backgroundColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.tag),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

/// 卡片内行间细淡分隔线，左右缩进与行内容对齐。
class _AgendaHairlineDivider extends StatelessWidget {
  const _AgendaHairlineDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Divider(
      height: 1,
      thickness: 0.5,
      indent: 12,
      endIndent: 12,
      color: theme.colorScheme.outlineVariant.withValues(
        alpha: isDark ? 0.28 : 0.45,
      ),
    );
  }
}
