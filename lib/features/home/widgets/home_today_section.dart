import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_surface_style.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import '../models/home_presentation.dart';

/// 精简节次文本：去掉「第」字与多余空格（例如 `第 3-5 节` → `3-5节`）。
@visibleForTesting
String formatTodayLesson(String raw) {
  final compact = raw.replaceAll(RegExp(r'\s+'), '');
  if (compact.startsWith('第') && compact.length > 1) {
    return compact.substring(1);
  }
  return compact;
}

/// 地点文本与 Hero 保持同一格式：`校区 楼栋教室` 原样展示（如
/// `梁林校区 博学楼(8号楼)501`），只做首尾空白清理；截断容差交给
/// 两行渲染解决，不重排顺序。
@visibleForTesting
String formatTodayLocation(String raw) => raw.trim();

/// Today Section（方案 A · 瑞士时间轴主卡）：当天剩余课程 + 今天考试；
/// 今天没有剩余安排时由 resolver 降级为次日预览形态（标题变为「开学首日 · …」
/// 或「明天」）。首页个性化「今天全部课程」开启时为全天形态
/// （[HomeTodayPresentation.isFullDay]），行数上限放宽到 6。
///
/// 当 `today.title == '今天'` 时卡片内部不再重复渲染「今天」标题（由外层
/// `_TodayZoneHeader` 承接「今天」）；次日预览形态则在卡片顶部以紧凑小标
/// 标示预览日期。无内容时整块不渲染；总行数超限时截断并在尾部展示「查看全部」。
///
/// 折叠形态（[HomeTodayPresentation.isCollapsed]）：Hero 已用课程大字
/// 展示命中日首课时，整段只剩单行「之后还有 N 门课 · 下一门 …」摘要，
/// 不渲染标题与课程行。
class HomeTodaySection extends StatelessWidget {
  const HomeTodaySection({super.key, required this.today, this.onOpenSchedule});

  final HomeTodayPresentation today;

  /// 「查看全部」点击回调（跳课表）；为空时不渲染截断尾行。
  final VoidCallback? onOpenSchedule;

  /// 时间列基准宽度，随系统字号倍率适度放大以维持等宽对齐。
  static const double _baseTimeColumnWidth = 50;
  static const double _railColumnWidth = 16;

  /// 最多展示的行数（考试 + 课程合计），超出部分折叠进「查看全部」。
  static const int _maxRows = 3;
  static const int _maxRowsFullDay = 6;

  /// 课程名：实时列表 16（`rowTitle`），次日预览降一档到 14（`titleSmall`）。
  static TextStyle _nameStyle(BuildContext context, bool compact) => compact
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
      section = _buildTimelineCard(
        context,
        primaryTextColor: primaryTextColor,
        secondaryTextColor: secondaryTextColor,
      );
    }

    final card = AppHardTileShell(
      radius: AppRadius.card,
      child: AppTileSurface(
        blurred: false,
        borderRadius: AppRadius.cardBorder,
        padding: EdgeInsets.fromLTRB(
          14,
          today.isCollapsed ? 2 : (today.title != '今天' ? 10 : 4),
          14,
          today.isCollapsed ? 2 : 4,
        ),
        onTap: onOpenSchedule,
        child: section,
      ),
    );

    // 整段可点进课表；有回调时才补充按钮语义。
    if (onOpenSchedule == null) return card;
    return Semantics(
      button: true,
      label: '${today.isCollapsed ? '后续课程' : today.title} · 查看课表',
      child: card,
    );
  }

  /// 折叠摘要单行：「之后还有 N 门课」+「下一门 时间 课程名」+ chevron。
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
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(
            '之后还有 $count 门课',
            style: context.appText.group.copyWith(
              color: cs.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detailText,
              style: context.appText.meta.copyWith(
                color: secondaryTextColor,
                fontFeatures: const [FontFeature.tabularFigures()],
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

  /// 完整时间轴列表形态：可选预览日期小标 + 瑞士时间轴条目 + 截断尾行。
  Widget _buildTimelineCard(
    BuildContext context, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
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

    final entries = <_TimelineEntry>[
      for (final exam in visibleExams) _TimelineEntry.exam(exam),
      for (final course in visibleCourses) _TimelineEntry.course(course),
    ];

    final showPreviewHeader = today.title != '今天';
    final textScale = MediaQuery.textScalerOf(context)
        .scale(1.0)
        .clamp(1.0, 1.8);
    final timeColumnWidth = _baseTimeColumnWidth * textScale;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showPreviewHeader) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              today.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.appText.group.copyWith(
                color: secondaryTextColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          _buildHairline(context),
        ],
        for (final (index, entry) in entries.indexed)
          _buildTimelineRow(
            context,
            entry,
            isFirst: index == 0,
            isLast: index == entries.length - 1,
            isSingle: entries.length == 1,
            timeColumnWidth: timeColumnWidth,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
        if (hiddenCount > 0 && onOpenSchedule != null) ...[
          _buildHairline(context),
          _buildMoreRow(
            context,
            hiddenCount,
            secondaryTextColor: secondaryTextColor,
          ),
        ],
      ],
    );
  }

  Widget _buildHairline(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Divider(
      height: 0.5,
      thickness: 0.5,
      color: theme.colorScheme.outlineVariant.withValues(
        alpha: isDark ? 0.28 : 0.45,
      ),
    );
  }

  /// 「查看全部」截断尾行：品牌色文字 + chevron。
  Widget _buildMoreRow(
    BuildContext context,
    int hiddenCount, {
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(
            '查看全部',
            style: context.appText.group.copyWith(color: cs.primary),
          ),
          Icon(Icons.chevron_right_rounded, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '还有 $hiddenCount 条 · 见课表',
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.appText.meta.copyWith(
                color: secondaryTextColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineRow(
    BuildContext context,
    _TimelineEntry entry, {
    required bool isFirst,
    required bool isLast,
    required bool isSingle,
    required double timeColumnWidth,
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final compact = today.isPreview;
    final verticalPad = compact ? 9.0 : 11.0;

    final isExam = entry.exam != null;
    final course = entry.course;
    final exam = entry.exam;
    final isOngoing = course?.isOngoing ?? false;
    final isDone = course?.isDone ?? false;

    final nameStyle = _nameStyle(context, compact);
    final textScaler = MediaQuery.textScalerOf(context);
    final firstLineHeight =
        textScaler.scale(nameStyle.fontSize ?? 16) * (nameStyle.height ?? 1.35);

    final timeStyle = context.appText.meta.copyWith(
      fontWeight: isDone || compact ? FontWeight.w500 : FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final timeLineHeight =
        textScaler.scale(timeStyle.fontSize ?? 13) * (timeStyle.height ?? 1.42);
    final timeTopOffset = ((firstLineHeight - timeLineHeight) / 2).clamp(
      0.0,
      8.0,
    );

    final Color timePrimaryColor;
    final Color timeSecondaryColor;
    final Color titleColor;
    final Color locationColor;
    if (isExam) {
      timePrimaryColor = cs.error;
      timeSecondaryColor = secondaryTextColor;
      titleColor = primaryTextColor;
      locationColor = secondaryTextColor;
    } else if (isOngoing) {
      timePrimaryColor = cs.primary;
      timeSecondaryColor = secondaryTextColor;
      titleColor = primaryTextColor;
      locationColor = secondaryTextColor;
    } else if (isDone) {
      timePrimaryColor = secondaryTextColor.withValues(alpha: 0.58);
      timeSecondaryColor = secondaryTextColor.withValues(alpha: 0.48);
      titleColor = secondaryTextColor.withValues(alpha: 0.72);
      locationColor = secondaryTextColor.withValues(alpha: 0.52);
    } else {
      timePrimaryColor = primaryTextColor;
      timeSecondaryColor = secondaryTextColor;
      titleColor = primaryTextColor;
      locationColor = secondaryTextColor;
    }

    final (String primaryTime, String secondaryTime) = isExam
        ? _splitExamTime(exam!.timeText)
        : (course!.timeText, formatTodayLesson(course.lessonText));

    final String rawTitle = isExam ? exam!.courseName : course!.courseName;
    final String formattedLocation = formatTodayLocation(
      isExam ? exam!.locationText : course!.locationText,
    );

    final _TimelineNodeKind nodeKind;
    if (isExam) {
      nodeKind = _TimelineNodeKind.exam;
    } else if (isOngoing) {
      nodeKind = _TimelineNodeKind.ongoing;
    } else if (isDone) {
      nodeKind = _TimelineNodeKind.done;
    } else {
      nodeKind = _TimelineNodeKind.upcoming;
    }

    final railColor = cs.outlineVariant.withValues(alpha: isDark ? 0.45 : 0.78);
    final upcomingRingColor = cs.outline.withValues(
      alpha: isDark ? 0.75 : 0.85,
    );
    final doneDotColor = secondaryTextColor.withValues(alpha: 0.35);

    // 「进行中」不打胶囊：强调色时间 + 实心节点已足够表达状态。
    final Widget? statusTag = isExam
        ? _TimelineStatusTag(
            label: '今天考试',
            backgroundColor: cs.error.withValues(alpha: isDark ? 0.18 : 0.10),
            foregroundColor: cs.error,
          )
        : null;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: timeColumnWidth,
            child: Padding(
              padding: EdgeInsets.only(
                top: verticalPad + timeTopOffset,
                bottom: verticalPad,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      primaryTime,
                      maxLines: 1,
                      style: timeStyle.copyWith(color: timePrimaryColor),
                    ),
                  ),
                  if (secondaryTime.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        secondaryTime,
                        maxLines: 1,
                        style: context.appText.tag.copyWith(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                          color: timeSecondaryColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 单条时不渲染时间轴：孤立的节点圆点没有意义，直接用留白分隔。
          if (isSingle)
            const SizedBox(width: 12)
          else ...[
            const SizedBox(width: 6),
            SizedBox(
              width: _railColumnWidth,
              child: CustomPaint(
                painter: _TimelineRailPainter(
                  isFirst: isFirst,
                  isLast: isLast,
                  nodeKind: nodeKind,
                  nodeCenterY: verticalPad + firstLineHeight / 2,
                  railColor: railColor,
                  primaryColor: cs.primary,
                  errorColor: cs.error,
                  upcomingRingColor: upcomingRingColor,
                  doneDotColor: doneDotColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: verticalPad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              rawTitle,
                              style: nameStyle.copyWith(
                                fontWeight: isDone || compact
                                    ? FontWeight.w500
                                    : FontWeight.w600,
                                color: titleColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (statusTag != null) ...[
                            const SizedBox(width: 6),
                            statusTag,
                          ],
                        ],
                      ),
                      if (formattedLocation.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          formattedLocation,
                          style: context.appText.meta.copyWith(
                            color: locationColor,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (!isLast) _buildHairline(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static (String, String) _splitExamTime(String raw) {
    final trimmed = raw.trim();
    final parts = trimmed.split('-');
    if (parts.length == 2 &&
        parts[0].trim().isNotEmpty &&
        parts[1].trim().isNotEmpty) {
      return (parts[0].trim(), '–${parts[1].trim()}');
    }
    return (trimmed, '考试');
  }
}

class _TimelineEntry {
  const _TimelineEntry.course(this.course) : exam = null;
  const _TimelineEntry.exam(this.exam) : course = null;

  final HomeTodayCourseRow? course;
  final HomeTodayExamRow? exam;
}

enum _TimelineNodeKind { exam, ongoing, upcoming, done }

class _TimelineStatusTag extends StatelessWidget {
  const _TimelineStatusTag({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.tag),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          style: context.appText.tag.copyWith(color: foregroundColor),
        ),
      ),
    );
  }
}

class _TimelineRailPainter extends CustomPainter {
  const _TimelineRailPainter({
    required this.isFirst,
    required this.isLast,
    required this.nodeKind,
    required this.nodeCenterY,
    required this.railColor,
    required this.primaryColor,
    required this.errorColor,
    required this.upcomingRingColor,
    required this.doneDotColor,
  });

  final bool isFirst;
  final bool isLast;
  final _TimelineNodeKind nodeKind;
  final double nodeCenterY;
  final Color railColor;
  final Color primaryColor;
  final Color errorColor;
  final Color upcomingRingColor;
  final Color doneDotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = nodeCenterY.clamp(6.0, size.height - 6.0);

    final nodeRadius = switch (nodeKind) {
      _TimelineNodeKind.exam => 4.0,
      _TimelineNodeKind.ongoing => 4.0,
      _TimelineNodeKind.upcoming => 3.5,
      _TimelineNodeKind.done => 3.0,
    };

    final railPaint = Paint()
      ..color = railColor
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.butt;

    final topEndY = cy - nodeRadius - 1.5;
    if (!isFirst && topEndY > 0) {
      canvas.drawLine(Offset(cx, 0), Offset(cx, topEndY), railPaint);
    }

    final bottomStartY = cy + nodeRadius + 1.5;
    if (!isLast && bottomStartY < size.height) {
      canvas.drawLine(
        Offset(cx, bottomStartY),
        Offset(cx, size.height),
        railPaint,
      );
    }

    switch (nodeKind) {
      case _TimelineNodeKind.exam:
        canvas.drawCircle(
          Offset(cx, cy),
          7.0,
          Paint()..color = errorColor.withValues(alpha: 0.12),
        );
        canvas.drawCircle(
          Offset(cx, cy),
          nodeRadius,
          Paint()..color = errorColor,
        );
      case _TimelineNodeKind.ongoing:
        canvas.drawCircle(
          Offset(cx, cy),
          7.5,
          Paint()..color = primaryColor.withValues(alpha: 0.12),
        );
        canvas.drawCircle(
          Offset(cx, cy),
          nodeRadius,
          Paint()..color = primaryColor,
        );
      case _TimelineNodeKind.upcoming:
        canvas.drawCircle(
          Offset(cx, cy),
          nodeRadius,
          Paint()
            ..color = upcomingRingColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      case _TimelineNodeKind.done:
        canvas.drawCircle(
          Offset(cx, cy),
          nodeRadius,
          Paint()..color = doneDotColor,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _TimelineRailPainter oldDelegate) {
    return oldDelegate.isFirst != isFirst ||
        oldDelegate.isLast != isLast ||
        oldDelegate.nodeKind != nodeKind ||
        oldDelegate.nodeCenterY != nodeCenterY ||
        oldDelegate.railColor != railColor ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.errorColor != errorColor ||
        oldDelegate.upcomingRingColor != upcomingRingColor ||
        oldDelegate.doneDotColor != doneDotColor;
  }
}
