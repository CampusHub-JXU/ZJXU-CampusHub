import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../schedule_constants.dart';
import '../schedule_model.dart';

class ScheduleCourseCell extends StatelessWidget {
  const ScheduleCourseCell({
    super.key,
    required this.course,
    required this.span,
    required this.color,
    required this.dayColumnWidth,
    required this.isCurrentWeek,
  });

  final CourseEntry course;
  final int span;
  final Color color;
  final double dayColumnWidth;
  final bool isCurrentWeek;

  static const _cellBorderRadius = BorderRadius.all(
    Radius.circular(AppRadius.chip),
  );

  static Color _blendColor(Color background, Color foreground, double amount) {
    return Color.lerp(background, foreground, amount)!;
  }

  void _showCourseDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (context) {
        final textTheme = Theme.of(context).textTheme;
        final cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: ConstrainedBox(
            // 大字号下详情行会增高：弹层内容高度有界并可滚动，避免溢出。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    course.courseName,
                    style: textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _DetailRow(
                    icon: Icons.person_outline,
                    text:
                        '教师：${course.teacherName.isEmpty ? scheduleUnknownText : course.teacherName}',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.meeting_room_outlined,
                    text:
                        '教室：${course.classroom.isEmpty ? scheduleUnknownText : course.classroom}',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.place_outlined,
                    text:
                        '校区：${course.campus.isEmpty ? scheduleUnknownText : course.campus}',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.schedule,
                    text: '节次：第 ${course.startLesson} - ${course.endLesson} 节',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.access_time_outlined,
                    text:
                        '时间：${ScheduleSlotTimes.timeRange(course.startLesson, course.endLesson)}',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.category_outlined,
                    text: '课程类型：${scheduleCourseTypeLabel(course.typeSymbol)}',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    icon: Icons.calendar_view_week,
                    text: '周次：${course.weekRange}',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cellBackgroundColor = isDark
        ? cs.surfaceContainerHigh
        : cs.surfaceContainerLowest;
    final cellFillColor = isCurrentWeek
        ? _blendColor(cellBackgroundColor, color, isDark ? 0.18 : 0.1)
        : _blendColor(
            cellBackgroundColor,
            cs.outlineVariant,
            isDark ? 0.04 : 0.06,
          );
    final titleColor = isCurrentWeek
        ? (isDark ? _blendColor(color, cs.onSurface, 0.24) : color)
        : cs.onSurfaceVariant;
    final metaColor = isCurrentWeek
        ? (isDark
              ? _blendColor(color, cs.onSurface, 0.14)
              : _blendColor(cellFillColor, titleColor, 0.75))
        : _blendColor(cellFillColor, cs.onSurfaceVariant, 0.75);
    final accentColor = isCurrentWeek
        ? color
        : _blendColor(color, cs.outline, 0.35);
    final cellHeight = scheduleGridSlotHeight * span;
    final narrow = dayColumnWidth < 24;
    final dense = cellHeight < 92;
    final titleFontSize = narrow ? 10.5 : 12.0;
    final metaFontSize = narrow ? 9.0 : 10.0;
    final hasRoom = !narrow && cellHeight >= 88;
    final hasExtraRoom = hasRoom && cellHeight >= 120;
    final titleLines = cellHeight >= 180
        ? (narrow ? 5 : 4)
        : cellHeight >= 120
        ? 3
        : 2;
    final classroomMaxLines = cellHeight >= 200 ? 4 : 2;
    final teacherMaxLines = cellHeight >= 160 ? 2 : 1;
    final showWeekTag = !isCurrentWeek && hasExtraRoom;

    return Semantics(
      button: true,
      label:
          '${course.courseName}，'
          '${course.classroom.isEmpty ? scheduleUnknownText : course.classroom}',
      child: SizedBox(
        width: dayColumnWidth,
        height: cellHeight,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Material(
            color: cellFillColor,
            borderRadius: _cellBorderRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _showCourseDetail(context),
              excludeFromSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ColoredBox(
                    color: accentColor,
                    child: const SizedBox(width: 4),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        narrow ? 2 : 4,
                        6,
                        narrow ? 2 : 4,
                        6,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Text(
                                course.courseName,
                                style: TextStyle(
                                  fontSize: titleFontSize,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor,
                                  height: dense ? 1.1 : 1.18,
                                ),
                                maxLines: titleLines,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          if (hasRoom || showWeekTag)
                            // 元信息块高度有界 + 不滚动裁剪：大字号下宁可省略，
                            // 也不让固定高度的课程块出现 RenderFlex 溢出。
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: cellHeight - 34,
                              ),
                              child: SingleChildScrollView(
                                physics: const NeverScrollableScrollPhysics(),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (hasRoom &&
                                        course.classroom.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Align(
                                        alignment: Alignment.bottomRight,
                                        child: Text(
                                          course.classroom,
                                          style: TextStyle(
                                            fontSize: metaFontSize,
                                            color: metaColor,
                                          ),
                                          maxLines: classroomMaxLines,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.right,
                                        ),
                                      ),
                                    ],
                                    if (hasRoom &&
                                        course.teacherName.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Align(
                                        alignment: Alignment.bottomRight,
                                        child: Text(
                                          course.teacherName,
                                          style: TextStyle(
                                            fontSize: metaFontSize,
                                            color: metaColor,
                                          ),
                                          maxLines: teacherMaxLines,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                    if (showWeekTag) ...[
                                      const SizedBox(height: 2),
                                      Align(
                                        alignment: Alignment.bottomRight,
                                        child: Text(
                                          scheduleInactiveWeekTag,
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: cs.onSurfaceVariant,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          softWrap: false,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}
