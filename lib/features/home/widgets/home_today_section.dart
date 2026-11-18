import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../models/home_presentation.dart';
import '../../../core/theme/app_typography.dart';

/// Today Section：当天剩余课程 + 今日考试的紧凑纯文字列表；今天没有
/// 剩余安排时由 resolver 降级为次日预览形态（标题变为「开学首日 · …」
/// 或「明天」）。首页个性化「今日全部课程」开启时为全天形态
///（[HomeTodayPresentation.isFullDay]）：列出今天一整天的课程，
/// 已结束的课不显示、进行中带胶囊，行数上限放宽到 6。
///
/// 标题 + 约 44 行高的单行条目（时间 / 课程名 / 地点），行间以留白节奏
/// 分组、不画分隔线，无卡片容器；无内容时整块不渲染。总行数超限时截断
/// 并在尾部展示「查看全部」（跳课表）。
///
/// 折叠形态（[HomeTodayPresentation.isCollapsed]）：Hero 已用课程大字
/// 展示命中日首课时，整段只剩单行「之后还有 N 门课 · 下一门 …」摘要，
/// 不渲染标题与课程行——次日列表不得与 Hero 抢视觉权重。
class HomeTodaySection extends StatelessWidget {
  const HomeTodaySection({super.key, required this.today, this.onOpenSchedule});

  final HomeTodayPresentation today;

  /// 「查看全部」点击回调（跳课表）；为空时不渲染截断尾行。
  final VoidCallback? onOpenSchedule;

  /// 时间列最小宽度，分隔线左缩进与其对齐。
  static const double _timeColumnWidth = 46;
  static const double _rowGap = 12;

  /// 最多展示的行数（考试 + 课程合计），超出部分折叠进「查看全部」。
  /// 全天模式行数上限放宽——同学要的就是一整天的安排。
  static const int _maxRows = 3;
  static const int _maxRowsFullDay = 6;

  /// 时间 / 地点列：实时列表 13（`secondary`），次日预览降一档到 12（`meta`）。
  static TextStyle _small(BuildContext context, bool compact) =>
      compact ? context.appText.meta : context.appText.secondary;

  /// 课程名：实时列表 15（`rowTitle`），次日预览降一档到 14（`titleSmall`）。
  static TextStyle _name(BuildContext context, bool compact) => compact
      ? Theme.of(context).textTheme.titleSmall!
      : context.appText.rowTitle;

  @override
  Widget build(BuildContext context) {
    if (today.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    final Widget section;
    if (today.isCollapsed) {
      section = _buildCollapsedSummary(
        context,
        secondaryTextColor: secondaryTextColor,
      );
    } else {
      section = _buildFullList(
        context,
        primaryTextColor: primaryTextColor,
        secondaryTextColor: secondaryTextColor,
      );
    }

    // 整段可点进课表（含标题与全部行）；有回调时才包手势层。
    if (onOpenSchedule == null) return section;
    return Semantics(
      button: true,
      label: '${today.isCollapsed ? '后续课程' : today.title} · 查看课表',
      child: InkWell(
        onTap: onOpenSchedule,
        borderRadius: BorderRadius.circular(12),
        child: section,
      ),
    );
  }

  /// 折叠摘要单行：「之后还有 N 门课」+「下一门 时间 课程名」+ chevron，
  /// 品牌色计数与「查看全部」尾行同一强调语言，整行由外层 InkWell 承接。
  Widget _buildCollapsedSummary(
    BuildContext context, {
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final count = today.courses.length;
    final next = today.courses.first;
    final detailText = count == 1
        ? '${next.timeText} ${next.courseName}'
        : '下一门 ${next.timeText} ${next.courseName}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Text(
            '之后还有 $count 门课',
            style: context.appText.label.copyWith(color: cs.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detailText,
              style: context.appText.secondary.copyWith(
                color: secondaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, size: 16, color: cs.primary),
        ],
      ),
    );
  }

  /// 完整列表形态：标题 + 行（考试在前）+ 截断尾行。
  Widget _buildFullList(
    BuildContext context, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    // 考试行在前、课程行在后（模型即分开存储）；合计超过上限截断。
    final maxRows = today.isFullDay ? _maxRowsFullDay : _maxRows;
    final visibleExams = today.exams.take(maxRows).toList();
    final visibleCourses = today.courses
        .take(maxRows - visibleExams.length)
        .toList();
    final hiddenCount =
        today.exams.length +
        today.courses.length -
        visibleExams.length -
        visibleCourses.length;
    final rows = <Widget>[
      for (final exam in visibleExams)
        _buildExamRow(
          context,
          exam,
          primaryTextColor: primaryTextColor,
          secondaryTextColor: secondaryTextColor,
        ),
      for (final course in visibleCourses)
        _buildCourseRow(
          context,
          course,
          primaryTextColor: primaryTextColor,
          secondaryTextColor: secondaryTextColor,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          today.title,
          style: context.appText.rowTitle.copyWith(
            fontWeight: FontWeight.w700,
            color: primaryTextColor,
          ),
        ),
        for (final (index, row) in rows.indexed) ...[
          if (index > 0) const SizedBox(height: AppSpacing.xs),
          row,
        ],
        if (hiddenCount > 0 && onOpenSchedule != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _buildMoreRow(context, hiddenCount),
        ],
      ],
    );
  }

  /// 「查看全部」截断尾行：品牌色文字 + chevron（点击由整段的
  /// InkWell 承接，这里不再单独包手势层）。
  Widget _buildMoreRow(BuildContext context, int hiddenCount) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Text(
            '查看全部',
            style: context.appText.label.copyWith(color: cs.primary),
          ),
          Icon(Icons.chevron_right_rounded, size: 16, color: cs.primary),
          const Spacer(),
          Text('还有 $hiddenCount 条 · 见课表', style: context.appText.meta),
        ],
      ),
    );
  }

  /// 课程行：时间 + 课程名（进行中加圆点与胶囊，全天模式已结束灰显）
  /// + 右对齐地点。
  Widget _buildCourseRow(
    BuildContext context,
    HomeTodayCourseRow course, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    // 次日预览形态整体降一档（14/12 字号 + 更紧行距），与实时的
    // 「今天」列表拉开层级——它是未来安排的轻量提示。
    final compact = today.isPreview;
    // 全天模式已结束的课：整行降为次要色，不与剩余课程抢视觉。
    final done = course.isDone;
    final nameColor = done ? secondaryTextColor : primaryTextColor;
    final timeColor = done
        ? secondaryTextColor.withValues(alpha: 0.6)
        : secondaryTextColor;
    return Padding(
      // 竖向 padding 撑起约 44 行高（预览 38），随 textScaler 自然缩放。
      padding: EdgeInsets.symmetric(vertical: compact ? 9 : 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _timeColumnWidth),
            child: Text(
              course.timeText,
              style: _small(context, compact).copyWith(
                fontWeight: FontWeight.w500,
                color: timeColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: _rowGap),
          Expanded(
            flex: 3,
            child: Row(
              children: [
                if (course.isOngoing) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    course.courseName,
                    style: _name(context, compact).copyWith(
                      fontWeight: done || compact
                          ? FontWeight.w500
                          : FontWeight.w600,
                      color: nameColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (course.isOngoing) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: ShapeDecoration(
                      color: cs.primary.withValues(alpha: 0.10),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(
                      '进行中',
                      style: context.appText.tag.copyWith(color: cs.primary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              course.locationText,
              style: _small(context, compact).copyWith(
                color: done
                    ? secondaryTextColor.withValues(alpha: 0.6)
                    : secondaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  /// 考试行：同课程行布局，时间列前以 error 色 event 图标标识。
  Widget _buildExamRow(
    BuildContext context,
    HomeTodayExamRow exam, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final compact = today.isPreview;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 9 : 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _timeColumnWidth),
            // 外层 Row 的非 flex 子节点宽度无上界，内层不能再套 flex 子节点。
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_outlined, size: 14, color: cs.error),
                const SizedBox(width: 4),
                Text(
                  exam.timeText,
                  style: _small(context, compact).copyWith(
                    fontWeight: FontWeight.w500,
                    color: secondaryTextColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: _rowGap),
          Expanded(
            flex: 3,
            child: Text(
              exam.courseName,
              style: _name(context, compact).copyWith(
                fontWeight: compact ? FontWeight.w500 : FontWeight.w600,
                color: primaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              exam.locationText,
              style: _small(
                context,
                compact,
              ).copyWith(color: secondaryTextColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
