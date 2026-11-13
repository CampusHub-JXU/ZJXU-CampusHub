import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_surface_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../core/academic/schedule_constants.dart';
import '../../../core/academic/schedule_model.dart';

/// 课表网格里的一个课程块（设计系统 v2 · `O1` 微字阶 + 8 色色板）。
///
/// 颜色不再由外部传入、也不再按主题色算色相：v2 规定色相由课程名稳定
/// 哈希到 8 个无障碍色相之一（[AppSurfaces.hueFor]），同一门课在任何设备、
/// 任何次启动、任何主题下都是同一个颜色；非本周课程统一走
/// [AppSurfaces.dimmedHue]（降饱和但不隐形）。
class ScheduleCourseCell extends StatelessWidget {
  const ScheduleCourseCell({
    super.key,
    required this.course,
    required this.span,
    required this.dayColumnWidth,
    required this.isCurrentWeek,
  });

  final CourseEntry course;
  final int span;
  final double dayColumnWidth;
  final bool isCurrentWeek;

  static const _cellBorderRadius = BorderRadius.all(
    Radius.circular(AppRadius.cell),
  );

  void _showCourseDetail(BuildContext context) {
    AppFeedback.sheet<void>(
      context,
      builder: (context) {
        final textTheme = Theme.of(context).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
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
    final surfaces = context.appSurfaces;
    final hue = isCurrentWeek
        ? surfaces.hueFor(course.courseName)
        : surfaces.dimmedHue;
    final titleColor = hue.foreground;
    final metaColor = hue.foreground.withValues(alpha: 0.78);
    // 颜色条 + 白 / 黑底：色相只落在左侧 3dp 竖条与文字上，底面积保持
    // 中性卡面，七列网格才不会变成一块花布。
    final accentColor = hue.foreground;
    final cellFillColor = isCurrentWeek ? surfaces.card : surfaces.tile;
    final cellHeight = scheduleGridSlotHeight * span;
    final narrow = dayColumnWidth < 24;
    final hasRoom = !narrow && cellHeight >= 88;
    final hasExtraRoom = hasRoom && cellHeight >= 120;
    // 课名最多 7 行：一节 68dp 的竖向空间本来就够，没必要提前截断。
    final titleLines = cellHeight >= 204
        ? 7
        : cellHeight >= 136
        ? 6
        : cellHeight >= 88
        ? 4
        : 2;
    final classroomMaxLines = cellHeight >= 200 ? 4 : 2;
    final teacherMaxLines = cellHeight >= 160 ? 2 : 1;
    final showWeekTag = !isCurrentWeek && hasExtraRoom;

    return Semantics(
      button: true,
      // 内层 InkWell 关闭了自身语义，这里补上等价的 tap 动作，避免无障碍
      // 服务只播报课程名却无法激活；同时排除子文本语义，保持单节点播报。
      excludeSemantics: true,
      label:
          '${course.courseName}，'
          '${course.classroom.isEmpty ? scheduleUnknownText : course.classroom}',
      onTap: () => _showCourseDetail(context),
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
                  // 颜色条：色相只在这里和文字上出现，底面积保持中性卡面。
                  ColoredBox(
                    color: accentColor,
                    child: const SizedBox(width: 3),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(2, 5, 2, 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Text(
                                course.courseName,
                                style: AppScheduleType.cellTitle.copyWith(
                                  color: titleColor,
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
                                          style: AppScheduleType.cellRoom
                                              .copyWith(color: metaColor),
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
                                          style: AppScheduleType.cellRoom
                                              .copyWith(color: metaColor),
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
                                          style: AppScheduleType.cellRoom
                                              .copyWith(color: surfaces.ink3),
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
