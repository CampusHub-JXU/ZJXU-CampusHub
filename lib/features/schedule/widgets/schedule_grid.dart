import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../core/academic/schedule_constants.dart';
import '../../../core/academic/schedule_date_override.dart';
import '../../../core/academic/schedule_model.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_surface_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../schedule_week_view_model.dart';
import 'schedule_course_cell.dart';
import 'schedule_day_headers.dart';
import 'schedule_date_override_editing.dart';
import 'schedule_edit_wiggle.dart';
import 'schedule_slot_column.dart';

class ScheduleGrid extends StatefulWidget {
  const ScheduleGrid({
    super.key,
    required this.weekViewModel,
    required this.actualCurrentWeek,
    this.isEditing = false,
    this.editReduced = false,
    this.wiggleListenable,
    this.overrideForCourse,
    this.onCourseLongPress,
    this.onCourseEditRequested,
    this.onCourseRevertRequested,
    this.onCourseMoved,
  });

  final ScheduleWeekViewModel weekViewModel;

  /// 真实当前周；null 表示当前不存在"本周"（未开学或学期已结束）。
  final int? actualCurrentWeek;

  /// 页面级编辑模式：本周有效课程抖动 / 高亮，且接受长按拖拽改期。
  final bool isEditing;

  /// 系统「移除动画」生效时的编辑态替代（描边高亮，不抖动）。
  final bool editReduced;

  /// 抖动共享驱动（`AnimationController`）；未处于可抖动状态可为 null。
  final Listenable? wiggleListenable;

  /// 查询展示中的课程是否已被「特定日期」编辑命中（用于「已调」徽标 /
  /// 详情弹层的回退入口）。
  final ScheduleDateOverride? Function(int week, CourseEntry course)?
  overrideForCourse;

  /// 长按本周有效课程块（进入编辑模式）。
  final void Function(int week, CourseEntry course)? onCourseLongPress;

  /// 编辑模式下点击课程块，或详情弹层「调整此日课程」。
  final void Function(int week, CourseEntry course)? onCourseEditRequested;

  /// 详情弹层「快捷回退」。返回是否已恢复（false 时弹层不关闭）。
  final Future<bool> Function(ScheduleDateOverride override)?
  onCourseRevertRequested;

  /// 拖拽落点变更：把课程移到 `(targetWeekday, targetStartLesson)`（保持原
  /// 节数跨度）。返回保存是否成功。
  final Future<bool> Function(
    int week,
    CourseEntry course,
    int targetWeekday,
    int targetStartLesson,
  )?
  onCourseMoved;

  int get currentWeek => weekViewModel.week;

  /// 该页展示的周是否就是真实「本周」——只有本周课程参与编辑交互。
  bool get editableWeek =>
      actualCurrentWeek != null && currentWeek == actualCurrentWeek;

  /// Merge adjacent/overlapping same-name courses on the same day into one
  /// entry spanning the full range, then deduplicate.
  static List<CourseEntry> mergeAdjacentCourses(List<CourseEntry> courses) {
    if (courses.length <= 1) return courses;

    // 实验附表按项目给出明确的节次，不应与同名课或相邻项目拼接。
    final groups = <(String, String), List<CourseEntry>>{};
    final merged = <CourseEntry>[];
    for (final c in courses) {
      if (c.fromLabSchedule) {
        merged.add(c);
      } else {
        (groups[(c.courseName, c.typeSymbol)] ??= []).add(c);
      }
    }
    for (final group in groups.values) {
      if (group.length == 1) {
        merged.add(group.first);
        continue;
      }

      group.sort((a, b) => a.startLesson.compareTo(b.startLesson));

      var current = group.first;
      for (var i = 1; i < group.length; i++) {
        final next = group[i];
        if (next.startLesson <= current.endLesson + 1) {
          // Merge: extend to cover next
          final newEnd = current.endLesson > next.endLesson
              ? current.endLesson
              : next.endLesson;
          current = CourseEntry(
            courseName: current.courseName,
            teacherName: current.teacherName,
            weekday: current.weekday,
            startLesson: current.startLesson,
            endLesson: newEnd,
            weekRange: current.weekRange,
            classroom: current.classroom.isNotEmpty
                ? current.classroom
                : next.classroom,
            campus: current.campus,
            typeSymbol: current.typeSymbol,
            courseCode: current.courseCode,
            hasScheduleChange:
                current.hasScheduleChange || next.hasScheduleChange,
          );
        } else {
          merged.add(current);
          current = next;
        }
      }
      merged.add(current);
    }

    return merged;
  }

  /// Deduplicate other-week courses, exclude those already in current week,
  /// and merge adjacent same-name entries.
  static List<CourseEntry> deduplicateBySlot(
    List<CourseEntry> otherCourses,
    List<CourseEntry> currentWeekCourses,
  ) {
    final currentKeys = <String>{};
    for (final c in currentWeekCourses) {
      currentKeys.add(
        '${c.courseName}|${c.typeSymbol}|${c.startLesson}|${c.endLesson}',
      );
    }

    final seen = <String>{};
    final deduped = otherCourses.where((course) {
      final key =
          '${course.courseName}|${course.typeSymbol}|${course.startLesson}|${course.endLesson}';
      if (currentKeys.contains(key)) return false;
      return seen.add(key);
    }).toList();

    return mergeAdjacentCourses(deduped);
  }

  @override
  State<ScheduleGrid> createState() => _ScheduleGridState();
}

class _ScheduleGridState extends State<ScheduleGrid> {
  final GlobalKey _scrollAreaKey = GlobalKey();
  _CourseDragState? _drag;
  double _dayColumnWidth = 0;

  bool get _gesturesEnabled =>
      widget.editableWeek && widget.isEditing && widget.onCourseMoved != null;

  /// 手指全局坐标 → 网格内容区坐标（节次列右侧、纵向已含滚动偏移）。
  Offset? _scrollLocalOf(Offset global) {
    final box = _scrollAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(global) -
        const Offset(scheduleGridSlotColumnWidth, 0);
  }

  void _beginDrag(_PlacedCourse placement, LongPressStartDetails details) {
    final entry = placement.entry;
    if (!_gesturesEnabled || !entry.isCurrentWeek) return;
    // 手指在课程块内的抓点（保持按住位置 → 目标左上角 = 手指 - 抓点）。
    setState(() {
      _drag = _CourseDragState(
        entry: entry,
        span: placement.span,
        cellWidth: placement.width,
        grabOffset: details.localPosition,
        fingerLocal: details.localPosition,
        targetWeekday: entry.course.weekday,
        targetStartLesson: entry.course.startLesson,
      );
    });
  }

  void _updateDrag(LongPressMoveUpdateDetails details) {
    final drag = _drag;
    if (drag == null) return;
    final local = _scrollLocalOf(details.globalPosition);
    if (local == null) return;
    final cellLeft = local.dx - drag.grabOffset.dx;
    final cellTop = local.dy - drag.grabOffset.dy;
    final maxStart = scheduleSlotCount - drag.span + 1;
    setState(() {
      drag.fingerLocal = local;
      // 课程块中心落在哪一列，目标就是哪一天（列号 0..6 → 星期 1..7）；
      // 起始节按左上角吸格（行号 0..12 → 节次 1..13）。
      drag.targetWeekday =
          (((cellLeft + _dayColumnWidth / 2) / _dayColumnWidth).floor() + 1)
              .clamp(1, 7);
      drag.targetStartLesson =
          (((cellTop / scheduleGridSlotHeight) + 0.5).floor() + 1).clamp(
            1,
            maxStart,
          );
    });
  }

  void _finishDrag({required bool cancelled}) {
    final drag = _drag;
    if (drag == null) return;
    final course = drag.entry.course;
    final targetWeekday = drag.targetWeekday;
    final targetStartLesson = drag.targetStartLesson;
    final moved =
        !cancelled &&
        (targetWeekday != course.weekday ||
            targetStartLesson != course.startLesson);
    setState(() => _drag = null);
    if (!moved) return;
    unawaited(
      widget.onCourseMoved?.call(
        widget.currentWeek,
        course,
        targetWeekday,
        targetStartLesson,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = context.appSurfaces;
    final editableWeek = widget.editableWeek;
    return LayoutBuilder(
      builder: (context, constraints) {
        final dayColumnWidth =
            (constraints.maxWidth - scheduleGridSlotColumnWidth) / 7;
        _dayColumnWidth = dayColumnWidth;

        // `O1` 硬约束：二维网格内文字缩放钳制在 [0.95, 1.08]，
        // 系统拉到 130% 也不会把 3 个汉字挤成 1 个半。
        return AppTextScaleGuard.scheduleGrid(
          child: Column(
            children: [
              ScheduleDayHeaders(
                slotColumnWidth: scheduleGridSlotColumnWidth,
                dayColumnWidth: dayColumnWidth,
                currentWeek: widget.currentWeek,
                isCurrentWeek: editableWeek,
              ),
              Expanded(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: CustomPaint(
                    // 极淡的节次横线（含节次列竖分隔线），只画在网格底层，
                    // 不参与内容布局。这是 v2 里唯一允许出现的辅助线：
                    // 二维时间 × 星期矩阵没有坐标线就读不出行列关系。
                    painter: _SlotGridLinePainter(color: surfaces.matrixLine),
                    child: Stack(
                      key: _scrollAreaKey,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ScheduleSlotColumn(
                              slotColumnWidth: scheduleGridSlotColumnWidth,
                            ),
                            for (int day = 1; day <= 7; day++)
                              RepaintBoundary(
                                child: _DayColumn(
                                  currentWeekCourses: widget.weekViewModel
                                      .coursesForDay(day)
                                      .currentWeekCourses,
                                  otherWeekCourses: widget.weekViewModel
                                      .coursesForDay(day)
                                      .otherWeekCourses,
                                  dayColumnWidth: dayColumnWidth,
                                  displayWeek: widget.currentWeek,
                                  isEditing: widget.isEditing,
                                  editEligibleWeek: editableWeek,
                                  editReduced: widget.editReduced,
                                  wiggleListenable: widget.wiggleListenable,
                                  overrideForCourse: widget.overrideForCourse,
                                  draggingEntry: _drag?.entry,
                                  onCourseLongPress: widget.onCourseLongPress,
                                  onCourseEditRequested:
                                      widget.onCourseEditRequested,
                                  onCourseRevertRequested:
                                      widget.onCourseRevertRequested,
                                  onDragStart: _gesturesEnabled
                                      ? _beginDrag
                                      : null,
                                  onDragUpdate: _gesturesEnabled
                                      ? _updateDrag
                                      : null,
                                  onDragEnd: _gesturesEnabled
                                      ? () => _commitDrag()
                                      : null,
                                  onDragCancel: _gesturesEnabled
                                      ? () => _cancelDrag()
                                      : null,
                                ),
                              ),
                          ],
                        ),
                        if (_drag != null) ...[
                          Positioned(
                            left:
                                (_drag!.targetWeekday - 1) * dayColumnWidth +
                                scheduleGridSlotColumnWidth,
                            top:
                                (_drag!.targetStartLesson - 1) *
                                scheduleGridSlotHeight,
                            width: dayColumnWidth,
                            height:
                                scheduleGridSlotHeight *
                                (_drag!.entry.course.endLesson -
                                        _drag!.entry.course.startLesson +
                                        1)
                                    .clamp(1, scheduleSlotCount),
                            child: IgnorePointer(
                              child: _DropTargetPreview(
                                weekday: _drag!.targetWeekday,
                                startLesson: _drag!.targetStartLesson,
                                endLesson:
                                    _drag!.targetStartLesson + _drag!.span - 1,
                              ),
                            ),
                          ),
                          Positioned(
                            left:
                                _drag!.fingerLocal.dx -
                                _drag!.grabOffset.dx +
                                scheduleGridSlotColumnWidth,
                            top: _drag!.fingerLocal.dy - _drag!.grabOffset.dy,
                            width: _drag!.cellWidth,
                            height: scheduleGridSlotHeight * _drag!.span,
                            child: IgnorePointer(
                              child: ExcludeSemantics(
                                child: _DragGhostCard(drag: _drag!),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _commitDrag() => _finishDrag(cancelled: false);
  void _cancelDrag() => _finishDrag(cancelled: true);
}

/// 拖拽会话：抓点 / 手指位置 / 目标槽位。手指与目标都以「节次列右侧为
/// x 原点」的网格内容区坐标记录。
class _CourseDragState {
  _CourseDragState({
    required this.entry,
    required this.span,
    required this.cellWidth,
    required this.grabOffset,
    required this.fingerLocal,
    required this.targetWeekday,
    required this.targetStartLesson,
  });

  final _DisplayCourseEntry entry;
  final int span;
  final double cellWidth;

  /// 抓点：手指相对课程块左上角的偏移（cell 本地坐标 = 列本地坐标，
  /// 因为课程块左上角即其在列内的布局点）。
  final Offset grabOffset;

  /// 手指在网格内容区（节次列右侧）的当前位置。
  Offset fingerLocal;
  int targetWeekday;
  int targetStartLesson;
}

/// 拖拽中目标落点的半透明预览框（`周X 第a-b节`）。
class _DropTargetPreview extends StatelessWidget {
  const _DropTargetPreview({
    required this.weekday,
    required this.startLesson,
    required this.endLesson,
  });

  final int weekday;
  final int startLesson;
  final int endLesson;

  @override
  Widget build(BuildContext context) {
    final surfaces = context.appSurfaces;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surfaces.brand.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.cell),
          border: Border.all(
            color: surfaces.brand.withValues(alpha: 0.55),
            width: 1.4,
          ),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                scheduleSlotLabel(weekday, startLesson, endLesson),
                style: AppScheduleType.cellRoom.copyWith(
                  color: surfaces.brand,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 手指处浮起跟随的课程卡片。
class _DragGhostCard extends StatelessWidget {
  const _DragGhostCard({required this.drag});

  final _CourseDragState drag;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.cell),
      child: ScheduleCourseCell(
        course: drag.entry.course,
        span: drag.span,
        dayColumnWidth: drag.cellWidth,
        isCurrentWeek: true,
        isEditing: false,
        dateOverride: null,
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.currentWeekCourses,
    required this.otherWeekCourses,
    required this.dayColumnWidth,
    required this.displayWeek,
    required this.isEditing,
    required this.editEligibleWeek,
    required this.editReduced,
    required this.wiggleListenable,
    required this.overrideForCourse,
    required this.draggingEntry,
    required this.onCourseLongPress,
    required this.onCourseEditRequested,
    required this.onCourseRevertRequested,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final List<CourseEntry> currentWeekCourses;
  final List<CourseEntry> otherWeekCourses;
  final double dayColumnWidth;
  final int displayWeek;
  final bool isEditing;
  final bool editEligibleWeek;
  final bool editReduced;
  final Listenable? wiggleListenable;
  final ScheduleDateOverride? Function(int week, CourseEntry course)?
  overrideForCourse;
  final _DisplayCourseEntry? draggingEntry;
  final void Function(int week, CourseEntry course)? onCourseLongPress;
  final void Function(int week, CourseEntry course)? onCourseEditRequested;
  final Future<bool> Function(ScheduleDateOverride override)?
  onCourseRevertRequested;
  final void Function(_PlacedCourse placement, LongPressStartDetails details)?
  onDragStart;
  final void Function(LongPressMoveUpdateDetails details)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragCancel;

  @override
  Widget build(BuildContext context) {
    final displayCourses = [
      ...currentWeekCourses.map(
        (course) => _DisplayCourseEntry(course: course, isCurrentWeek: true),
      ),
      ...otherWeekCourses.map(
        (course) => _DisplayCourseEntry(course: course, isCurrentWeek: false),
      ),
    ];

    final placements = _buildCoursePlacements(displayCourses);

    return SizedBox(
      width: dayColumnWidth,
      height: scheduleGridSlotHeight * scheduleSlotCount,
      child: Stack(
        children: [
          for (final placement in placements)
            Positioned(
              left: placement.left,
              top:
                  (placement.entry.course.startLesson - 1) *
                  scheduleGridSlotHeight,
              width: placement.width,
              height: scheduleGridSlotHeight * placement.span,
              child: RepaintBoundary(child: _buildCell(context, placement)),
            ),
        ],
      ),
    );
  }

  Widget _buildCell(BuildContext context, _PlacedCourse placement) {
    final entry = placement.entry;
    final course = entry.course;
    final editable = entry.isCurrentWeek && editEligibleWeek;
    final override = entry.isCurrentWeek
        ? overrideForCourse?.call(displayWeek, course)
        : null;
    final cell = ScheduleCourseCell(
      course: course,
      span: placement.span,
      dayColumnWidth: placement.width,
      isCurrentWeek: entry.isCurrentWeek,
      isEditing: isEditing && editable,
      editEligible: editable,
      editReduced: editReduced,
      dragging: identical(draggingEntry, entry),
      wiggleListenable: wiggleListenable,
      wigglePhase: ScheduleWiggleDriver.courseWigglePhase(course),
      dateOverride: override,
      onLongPress: editable && onCourseLongPress != null
          ? () => onCourseLongPress!(displayWeek, course)
          : null,
      onRequestEdit: entry.isCurrentWeek && onCourseEditRequested != null
          ? () => onCourseEditRequested!(displayWeek, course)
          : null,
      onRequestRevert: override != null && onCourseRevertRequested != null
          ? () => onCourseRevertRequested!(override)
          : null,
    );
    if (!editable || onDragStart == null) return cell;
    // 编辑模式下的按住拖动：长按手势识别器与块内 InkWell 的 tap 共存，
    // 拖起来即由这里接管（tap 自然落败）；快速点按仍走 onRequestEdit。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (details) => onDragStart!(placement, details),
      onLongPressMoveUpdate: onDragUpdate,
      onLongPressEnd: (_) => onDragEnd?.call(),
      onLongPressCancel: () => onDragCancel?.call(),
      child: cell,
    );
  }

  List<_PlacedCourse> _buildCoursePlacements(
    List<_DisplayCourseEntry> displayCourses,
  ) {
    if (displayCourses.isEmpty) return const [];

    final sortedCourses = [...displayCourses]
      ..sort((a, b) {
        final byStart = a.course.startLesson.compareTo(b.course.startLesson);
        if (byStart != 0) return byStart;

        if (a.isCurrentWeek != b.isCurrentWeek) {
          return a.isCurrentWeek ? -1 : 1;
        }

        final byEnd = a.course.endLesson.compareTo(b.course.endLesson);
        if (byEnd != 0) return byEnd;

        return a.course.courseName.compareTo(b.course.courseName);
      });

    final placements = <_PlacedCourse>[];
    final clusters = <List<_DisplayCourseEntry>>[];
    var currentCluster = <_DisplayCourseEntry>[];
    var clusterEnd = 0;

    for (final course in sortedCourses) {
      if (currentCluster.isEmpty || course.course.startLesson > clusterEnd) {
        if (currentCluster.isNotEmpty) clusters.add(currentCluster);
        currentCluster = [course];
        clusterEnd = course.course.endLesson;
        continue;
      }

      currentCluster.add(course);
      if (course.course.endLesson > clusterEnd) {
        clusterEnd = course.course.endLesson;
      }
    }

    if (currentCluster.isNotEmpty) clusters.add(currentCluster);

    for (final cluster in clusters) {
      placements.addAll(_buildClusterPlacements(cluster));
    }

    return placements;
  }

  List<_PlacedCourse> _buildClusterPlacements(
    List<_DisplayCourseEntry> cluster,
  ) {
    final currentEntries = cluster
        .where((entry) => entry.isCurrentWeek)
        .toList();
    final otherEntries = cluster
        .where((entry) => !entry.isCurrentWeek)
        .toList();

    if (currentEntries.isNotEmpty) {
      // Current-week courses take full width; hide non-current-week to avoid conflict
      return _buildStandardPlacements(currentEntries, dayColumnWidth);
    }

    // No current-week courses in this slot — show closest non-current-week at full width
    // Only if within 3 weeks of displayed week to avoid clutter
    if (otherEntries.isEmpty) return const [];

    var closest = otherEntries.first;
    var closestDistance = closest.course.weekDistanceTo(displayWeek);
    for (final entry in otherEntries.skip(1)) {
      final distance = entry.course.weekDistanceTo(displayWeek);
      if (distance < closestDistance) {
        closest = entry;
        closestDistance = distance;
      }
    }
    if (closestDistance > 3) return const [];

    return _buildStandardPlacements([closest], dayColumnWidth);
  }

  List<_PlacedCourse> _buildStandardPlacements(
    List<_DisplayCourseEntry> entries,
    double availableWidth,
  ) {
    if (entries.isEmpty) return const [];

    final assignments = _assignColumns(entries);
    final totalColumns = assignments.fold<int>(
      0,
      (maxColumns, assignment) => assignment.column + 1 > maxColumns
          ? assignment.column + 1
          : maxColumns,
    );
    final columnWidth = availableWidth / totalColumns;

    return assignments.map((assignment) {
      final span =
          (assignment.entry.course.endLesson -
                  assignment.entry.course.startLesson +
                  1)
              .clamp(
                1,
                scheduleSlotCount - assignment.entry.course.startLesson + 1,
              );

      return _PlacedCourse(
        entry: assignment.entry,
        left: assignment.column * columnWidth,
        width: columnWidth,
        span: span,
      );
    }).toList();
  }

  List<_ColumnAssignment> _assignColumns(List<_DisplayCourseEntry> entries) {
    final assignments = <_ColumnAssignment>[];
    final columnEndLessons = <int>[];

    for (final entry in entries) {
      var targetColumn = -1;

      for (var i = 0; i < columnEndLessons.length; i++) {
        if (columnEndLessons[i] < entry.course.startLesson) {
          targetColumn = i;
          break;
        }
      }

      if (targetColumn == -1) {
        targetColumn = columnEndLessons.length;
        columnEndLessons.add(entry.course.endLesson);
      } else {
        columnEndLessons[targetColumn] = entry.course.endLesson;
      }

      assignments.add(_ColumnAssignment(entry: entry, column: targetColumn));
    }

    return assignments;
  }
}

class _DisplayCourseEntry {
  const _DisplayCourseEntry({
    required this.course,
    required this.isCurrentWeek,
  });

  final CourseEntry course;
  final bool isCurrentWeek;
}

class _ColumnAssignment {
  const _ColumnAssignment({required this.entry, required this.column});

  final _DisplayCourseEntry entry;
  final int column;
}

class _PlacedCourse {
  const _PlacedCourse({
    required this.entry,
    required this.left,
    required this.width,
    required this.span,
  });

  final _DisplayCourseEntry entry;
  final double left;
  final double width;
  final int span;
}

/// 课表网格底层的节次分隔线：每节一条横线 + 节次列右侧一条竖线。
/// 纯装饰、不参与布局，透明度取 outlineVariant 低值，避免与课程块抢层级。
class _SlotGridLinePainter extends CustomPainter {
  const _SlotGridLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.6;
    for (var i = 1; i < scheduleSlotCount; i++) {
      final y = i * scheduleGridSlotHeight;
      if (y >= size.height) break;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    canvas.drawLine(
      Offset(scheduleGridSlotColumnWidth, 0),
      Offset(scheduleGridSlotColumnWidth, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SlotGridLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
