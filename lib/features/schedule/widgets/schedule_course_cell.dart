import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_surface_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../core/academic/schedule_constants.dart';
import '../../../core/academic/schedule_date_override.dart';
import '../../../core/academic/schedule_model.dart';
import 'schedule_edit_wiggle.dart';

/// 课表网格里的一个课程块（设计系统 v2 · `O1` 微字阶 + 8 色色板）。
///
/// 颜色不再由外部传入、也不再按主题色算色相：v2 规定色相由课程名稳定
/// 哈希到 8 个无障碍色相之一（[AppSurfaces.hueFor]），同一门课在任何设备、
/// 任何次启动、任何主题下都是同一个颜色；非本周课程统一走
/// [AppSurfaces.dimmedHue]（降饱和但不隐形）。
///
/// 特定日期编辑相关参数：
/// * [editEligible]：该课程块是否参与手动调整（本周有效课程才允许长按 /
///   拖拽 / 点击编辑；非本周灰块全部忽略）；
/// * [isEditing]：是否处于长按进入的编辑模式（配合 [wiggleListenable] /
///   [editReduced] 呈现抖动或高亮态）；
/// * [dragging]：正在被触控移动，原位留半透明虚影；
/// * [dateOverride]：命中本课程的既有「特定日期」编辑，用于「已调」徽标与
///   详情弹层的「已手动调整 / 快捷回退」。
class ScheduleCourseCell extends StatelessWidget {
  const ScheduleCourseCell({
    super.key,
    required this.course,
    required this.span,
    required this.dayColumnWidth,
    required this.isCurrentWeek,
    this.isEditing = false,
    this.editEligible = false,
    this.editReduced = false,
    this.dragging = false,
    this.wiggleListenable,
    this.wigglePhase = 0,
    this.dateOverride,
    this.onLongPress,
    this.onRequestEdit,
    this.onRequestRevert,
  });

  final CourseEntry course;
  final int span;
  final double dayColumnWidth;
  final bool isCurrentWeek;

  /// 页面级编辑模式开关。
  final bool isEditing;

  /// 是否允许长按 / 拖拽 / 点击编辑（本周有效课程）。
  final bool editEligible;

  /// 编辑模式下系统「移除动画」生效时的替代态：不抖动，改描边高亮。
  final bool editReduced;

  /// 拖拽中原位虚影（半透明）。
  final bool dragging;

  /// 编辑模式抖动驱动；null 或 [editReduced] 为 true 时不抖动。
  final Listenable? wiggleListenable;

  /// 抖动相位（见 [ScheduleWiggleDriver.courseWigglePhase]）。
  final double wigglePhase;

  /// 命中本课程的特定日期编辑；null 表示尚未手动调整。
  final ScheduleDateOverride? dateOverride;

  /// 长按进入编辑模式（仅 [editEligible] 课程注册）。
  final VoidCallback? onLongPress;

  /// 编辑模式下点击打开「特定日期课程编辑」弹层。
  final VoidCallback? onRequestEdit;

  /// 详情弹层「快捷回退」；返回是否已恢复原课（false 时弹层保持打开）。
  final Future<bool> Function()? onRequestRevert;

  static const _cellBorderRadius = BorderRadius.all(
    Radius.circular(AppRadius.cell),
  );

  void _showCourseDetail(BuildContext context) {
    final override = dateOverride;
    final onRequestEdit = this.onRequestEdit;
    final onRequestRevert = this.onRequestRevert;
    AppFeedback.sheet<void>(
      context,
      builder: (sheetContext) {
        final textTheme = Theme.of(sheetContext).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: ConstrainedBox(
            // 大字号下详情行会增高：弹层内容高度有界并可滚动，避免溢出。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
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
                  if (override != null) ...[
                    const SizedBox(height: 12),
                    _DetailRow(
                      icon: Icons.edit_calendar_outlined,
                      text:
                          '已手动调整（原课：${override.sourceDate} 周${scheduleWeekdayLabels[override.sourceWeekday - 1]} 第${override.sourceStartLesson}-${override.sourceEndLesson}节）',
                    ),
                  ],
                  if (override != null || onRequestEdit != null) ...[
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        if (override != null && onRequestRevert != null)
                          Expanded(
                            child: TextButton(
                              onPressed: () async {
                                final ok = await onRequestRevert();
                                if (!sheetContext.mounted) return;
                                if (ok) Navigator.of(sheetContext).pop();
                              },
                              child: const Text('快捷回退'),
                            ),
                          ),
                        if (onRequestEdit != null)
                          Expanded(
                            child: FilledButton.tonal(
                              onPressed: () {
                                Navigator.of(sheetContext).pop();
                                onRequestEdit();
                              },
                              child: const Text('调整此日课程'),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOverrideIndicator(Color foreground) {
    // 虚线描边 + 右上角 5dp 课程色圆点：零遮挡课名，一眼区分临时调整课与教务原课。
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!isEditing)
          Padding(
            padding: const EdgeInsets.all(2),
            child: CustomPaint(
              painter: _DashedCellBorderPainter(
                color: foreground.withValues(alpha: 0.55),
                radius: AppRadius.cell,
              ),
            ),
          ),
        Positioned(
          top: 7,
          right: 7,
          child: Container(
            key: const ValueKey('schedule-override-indicator'),
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: foreground,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
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
    // 列宽 ≈44dp 时一行仅 3~4 个汉字，场地 / 教师行易折行成一团；
    // 把元信息门槛从 88dp（2 节）抬到 120dp，矮块只留课名，密度立刻松下来。
    final hasRoom = !narrow && cellHeight >= 120;
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
    // 「已调」徽标纯悬浮在右上角（半透明底、允许与课名重叠），
    // 不再给课名区预留空间——预留会把本就狭窄的课名再挤窄一截。
    final showOverrideBadge = dateOverride != null;
    final wiggleEnabled = isEditing && !editReduced && wiggleListenable != null;

    Widget cell = Semantics(
      button: true,
      // 内层 InkWell 关闭了自身语义，这里补上等价的 tap 动作，避免无障碍
      // 服务只播报课程名却无法激活；同时排除子文本语义，保持单节点播报。
      excludeSemantics: true,
      label:
          '${course.courseName}，'
          '${course.classroom.isEmpty ? scheduleUnknownText : course.classroom}'
          '${showOverrideBadge ? '，已手动调整' : ''}',
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
              onTap: isEditing && editEligible
                  ? onRequestEdit
                  : () => _showCourseDetail(context),
              // 编辑模式下长按手势让位给外层拖拽识别器（否则内层
              // InkWell 先入竞技场会赢掉外层，拖不动课程块）。
              onLongPress: editEligible && !isEditing ? onLongPress : null,
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
                      padding: const EdgeInsets.fromLTRB(3, 5, 3, 5),
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

    if (showOverrideBadge) {
      // 虚线描边 + 右上角指示点：命中有特定日期编辑的课程一眼可辨，
      // 不再遮挡课名，事件穿透到下层 InkWell。
      cell = Stack(
        fit: StackFit.expand,
        children: [
          cell,
          IgnorePointer(child: _buildOverrideIndicator(accentColor)),
        ],
      );
    }

    if (isEditing && editEligible) {
      // 编辑态描边：「移除动画」下是全量主色描边（替代抖动）；正常抖动
      // 状态下保留一层 1px 微弱主色描边，让可拖动块有「浮起」的可感知度。
      final borderColor = editReduced
          ? surfaces.brand
          : surfaces.brand.withValues(alpha: 0.25);
      cell = Stack(
        fit: StackFit.expand,
        children: [
          cell,
          IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('schedule-edit-highlight'),
              decoration: BoxDecoration(
                border: Border.all(
                  color: borderColor,
                  width: editReduced ? 1.6 : 1,
                ),
                borderRadius: _cellBorderRadius,
              ),
            ),
          ),
        ],
      );
    }

    if (wiggleEnabled) {
      cell = AnimatedBuilder(
        animation: wiggleListenable!,
        builder: (context, child) {
          final value = wiggleListenable is Animation<double>
              ? (wiggleListenable! as Animation<double>).value
              : 0.0;
          return Transform.rotate(
            key: const ValueKey('schedule-wiggle'),
            angle: ScheduleWiggleDriver.angleOf(value, wigglePhase),
            child: child,
          );
        },
        child: cell,
      );
    }

    if (dragging) {
      cell = Opacity(opacity: 0.35, child: cell);
    }
    return cell;
  }
}

class _DashedCellBorderPainter extends CustomPainter {
  const _DashedCellBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.55),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;

    const dashLength = 4.0;
    const gapLength = 3.2;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dashLength).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashLength + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedCellBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
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
