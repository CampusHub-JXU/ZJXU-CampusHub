import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/academic/schedule_constants.dart';
import '../../../core/academic/schedule_date_override.dart';
import '../../../core/academic/schedule_model.dart';
import '../../../core/semester/semester_calendar.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_surface_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_dropdown.dart';
import 'schedule_date_override_editing.dart';

/// 「特定日期课程编辑」底部弹层：调整该次课的星期 / 节次 / 地点 / 老师。
///
/// 通过 `AppFeedback.sheet` 打开；[existingOverride] 非空表示该次课已被
/// 手动调整过，此时展示「快捷回退」入口（恢复原课）。保存与回退都返回
/// `Future<bool>`（false = 当前无已验证身份或持久化被拒），弹层关闭时以
/// `'saved'` / `'reverted'` 回报结果，调用方据此弹轻提示。
class ScheduleCourseEditSheet extends StatefulWidget {
  const ScheduleCourseEditSheet({
    super.key,
    required this.week,
    required this.course,
    required this.existingOverride,
    required this.onSave,
    this.onRevert,
  });

  /// 本次课当前展示的周次（拖拽 / 编辑都发生在同一周视图内）。
  final int week;

  /// 本次课当前展示的课程条目（已应用 override 合成后的状态）。
  final CourseEntry course;

  /// 命中本课程的既有编辑；null 表示尚未调整过。
  final ScheduleDateOverride? existingOverride;

  /// 提交编辑：由调用方构造好 override 后交回持久化。
  final Future<bool> Function(ScheduleDateOverride override) onSave;

  /// 快捷回退：非空（仅 [existingOverride] 存在时给出）时展示回退按钮。
  final Future<bool> Function(ScheduleDateOverride override)? onRevert;

  @override
  State<ScheduleCourseEditSheet> createState() =>
      _ScheduleCourseEditSheetState();
}

class _ScheduleCourseEditSheetState extends State<ScheduleCourseEditSheet> {
  late final TextEditingController _classroomController;
  late final TextEditingController _teacherController;
  late int _weekday;
  late int _startLesson;
  late int _endLesson;
  bool _busy = false;

  ScheduleDateOverride? get _existing => widget.existingOverride;

  @override
  void initState() {
    super.initState();
    // 表单初值以「当前展示状态」为准：已移动过的课继续改的是移动后的落点，
    // 原课程字段由 buildCourseEditOverride 在 existing 路径下原样保留。
    _weekday = widget.course.weekday;
    _startLesson = widget.course.startLesson;
    _endLesson = widget.course.endLesson;
    _classroomController = TextEditingController(text: widget.course.classroom);
    _teacherController = TextEditingController(text: widget.course.teacherName);
  }

  @override
  void dispose() {
    _classroomController.dispose();
    _teacherController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final override = buildCourseEditOverride(
      week: widget.week,
      course: widget.course,
      existing: _existing,
      targetWeekday: _weekday,
      targetStartLesson: _startLesson,
      targetEndLesson: _endLesson,
      targetClassroom: _classroomController.text,
      targetTeacherName: _teacherController.text,
    );
    final ok = await widget.onSave(override);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop('saved');
      return;
    }
    setState(() => _busy = false);
  }

  Future<void> _revert() async {
    final override = _existing;
    final onRevert = widget.onRevert;
    if (_busy || override == null || onRevert == null) return;
    setState(() => _busy = true);
    final ok = await onRevert(override);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop('reverted');
      return;
    }
    setState(() => _busy = false);
  }

  /// 外置字段标题 + 输入框：标题样式与 [AppDropdown] 的 `label` 完全
  /// 一致，输入框本身交给 `InputDecorationTheme`（圆角无边框填充）。
  Widget _buildLabeledField(
    BuildContext context, {
    required String label,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        child,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final surfaces = context.appSurfaces;
    final existing = _existing;
    final weekStart = SemesterCalendar.instance.weekStartFor(widget.week);
    final currentDate = weekStart.add(
      Duration(days: widget.course.weekday - 1),
    );
    final headerDate =
        '${formatScheduleDate(currentDate)} · 第${widget.week}周 · '
        '周${scheduleWeekdayLabels[widget.course.weekday - 1]}';
    // 已移动过的课在标题下补一行「原课」定位，方便确认这次回退恢复的是哪节课。
    final sourceLabel = existing == null
        ? null
        : '原课：${existing.sourceDate} '
              '周${scheduleWeekdayLabels[existing.sourceWeekday - 1]} '
              '第${existing.sourceStartLesson}-${existing.sourceEndLesson}节';

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        // 键盘弹起时贴其上沿；否则至少让主按钮离开系统导航手势条。
        20 +
            math.max(
              MediaQuery.viewInsetsOf(context).bottom,
              MediaQuery.paddingOf(context).bottom,
            ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.course.courseName,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(headerDate, style: context.appText.meta),
              if (sourceLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  sourceLabel,
                  style: context.appText.meta.copyWith(color: surfaces.brand),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              AppDropdown<int>(
                label: '星期',
                value: _weekday,
                items: [
                  for (var i = 0; i < scheduleWeekdayLabels.length; i++)
                    AppDropdownItem(
                      value: i + 1,
                      label: '周${scheduleWeekdayLabels[i]}',
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _weekday = value);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppDropdown<int>(
                      label: '开始节',
                      value: _startLesson,
                      items: [
                        for (var i = 1; i <= scheduleSlotCount; i++)
                          AppDropdownItem(value: i, label: '第$i节'),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _startLesson = value;
                          if (_endLesson < value) _endLesson = value;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppDropdown<int>(
                      label: '结束节',
                      value: _endLesson,
                      items: [
                        for (var i = _startLesson; i <= scheduleSlotCount; i++)
                          AppDropdownItem(value: i, label: '第$i节'),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _endLesson = value);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _buildLabeledField(
                context,
                label: '上课地点',
                child: TextField(
                  controller: _classroomController,
                  decoration: const InputDecoration(
                    hintText: '教室 / 教学楼',
                    prefixIcon: Icon(Icons.location_on_outlined, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _buildLabeledField(
                context,
                label: '任课教师',
                child: TextField(
                  controller: _teacherController,
                  decoration: const InputDecoration(
                    hintText: '教师姓名',
                    prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (existing == null)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(_busy ? '保存中…' : '保存调整'),
                  ),
                )
              else
                // 已调整过的课：回退与保存并排展示，避免竖排把主按钮挤出
                // 首屏折叠线外。
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Tooltip(
                        message: '快捷回退，撤销本次调整',
                        child: OutlinedButton(
                          onPressed: _busy ? null : _revert,
                          child: const Text('恢复原课'),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 3,
                      child: FilledButton(
                        onPressed: _busy ? null : _save,
                        child: Text(_busy ? '保存中…' : '保存调整'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
