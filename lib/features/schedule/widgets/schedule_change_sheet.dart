import 'package:flutter/material.dart';

import '../../../core/academic/schedule_change_rule.dart';
import '../../../core/academic/schedule_constants.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_status_tag.dart';

/// 纯展示层判定「只换教室」：调课且原/新时段相同（或缺一方），
/// 新教室非空且与原教室不同。
bool isRoomOnlyChange(CourseChangeRule rule) {
  if (rule.type != CourseChangeType.reschedule) return false;
  final newRoom = (rule.classroom ?? '').trim();
  if (newRoom.isEmpty) return false;
  if (newRoom == (rule.originalClassroom ?? '').trim()) return false;
  final original = rule.originalLesson;
  final target = rule.targetLesson;
  if (original == null || target == null) return true;
  return _sameSlot(original, target);
}

bool _sameSlot(CourseLessonSlot a, CourseLessonSlot b) =>
    a.week == b.week &&
    a.weekday == b.weekday &&
    a.startLesson == b.startLesson &&
    a.endLesson == b.endLesson;

/// 调课提醒底部抽屉。
///
/// - 分段控件「已显示 N / 待确认 N」一次只看一组：分段本身即状态，
///   不误称待确认提醒已自动应用到课表。
/// - 卡片：类型 tag + 课程名 + 教师；调课/补课为「原 / 改」对照，
///   换教室单行「时段 旧教室 → 新教室」，停课单行删除线 +「停课」；
///   原文默认收起在「查看原文」里。
/// - 待确认卡为 `outlineVariant` 描边无填充，副行说明原因
///   （学期未标注 / 课表未显示）。
/// - 颜色全部来自 [ColorScheme]，无硬编码色。
class ScheduleChangeSheet extends StatefulWidget {
  const ScheduleChangeSheet({
    super.key,
    this.notices = const [],
    this.changeRules = const [],
    required this.displayWeek,
    required this.scrollController,
    this.currentWeek,
  });

  final List<CourseChangeNotice> notices;
  final List<CourseChangeRule> changeRules;
  final int displayWeek;
  final ScrollController scrollController;

  /// 实际当前教学周；非空时头部显示「本周 · 第 N 周」，并在时段中省略本周周次。
  final int? currentWeek;

  @override
  State<ScheduleChangeSheet> createState() => _ScheduleChangeSheetState();
}

class _ScheduleChangeSheetState extends State<ScheduleChangeSheet> {
  CourseChangeNoticeStatus? _selected;

  List<CourseChangeNotice> get _effectiveNotices {
    if (widget.notices.isNotEmpty) return widget.notices;
    return widget.changeRules
        .map(
          (rule) => CourseChangeNotice(
            rule: rule,
            status: CourseChangeNoticeStatus.unapplied,
          ),
        )
        .toList();
  }

  void _select(CourseChangeNoticeStatus status) {
    if (status == _selected) return;
    setState(() => _selected = status);
    if (widget.scrollController.hasClients) {
      widget.scrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final notices = _effectiveNotices;

    final reflected = notices.where((n) => n.isReflected).toList()
      ..sort((a, b) => _compareRuleOrder(a.rule, b.rule));
    final unapplied = notices.where((n) => n.isUnapplied).toList()
      ..sort((a, b) => _compareRuleOrder(a.rule, b.rule));

    // 有已显示项默认看已显示，否则看待确认；选中组被清空时回退到另一组。
    var selected =
        _selected ??
        (reflected.isNotEmpty
            ? CourseChangeNoticeStatus.reflected
            : CourseChangeNoticeStatus.unapplied);
    if (selected == CourseChangeNoticeStatus.reflected && reflected.isEmpty) {
      selected = CourseChangeNoticeStatus.unapplied;
    } else if (selected == CourseChangeNoticeStatus.unapplied &&
        unapplied.isEmpty &&
        reflected.isNotEmpty) {
      selected = CourseChangeNoticeStatus.reflected;
    }
    final visible = selected == CourseChangeNoticeStatus.reflected
        ? reflected
        : unapplied;

    final currentWeek = widget.currentWeek;
    final headerTrailing = currentWeek != null
        ? '本周 · 第 $currentWeek 周'
        : '共 ${notices.length} 条';

    return Column(
      children: [
        const SizedBox(height: 10),
        Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  '调课提醒',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Text(headerTrailing, style: context.appText.secondary),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<CourseChangeNoticeStatus>(
              key: const Key('schedule_change_segments'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: CourseChangeNoticeStatus.reflected,
                  label: Text('已显示 ${reflected.length}'),
                  enabled: reflected.isNotEmpty,
                ),
                ButtonSegment(
                  value: CourseChangeNoticeStatus.unapplied,
                  label: Text('待确认 ${unapplied.length}'),
                  enabled: unapplied.isNotEmpty,
                ),
              ],
              selected: {selected},
              onSelectionChanged: (value) => _select(value.first),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            physics: const ClampingScrollPhysics(),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) =>
                _buildNoticeCard(context, visible[index]),
          ),
        ),
      ],
    );
  }

  int _compareRuleOrder(CourseChangeRule left, CourseChangeRule right) {
    final leftWeek = _ruleWeek(left);
    final rightWeek = _ruleWeek(right);
    final leftDistance = (leftWeek - widget.displayWeek).abs();
    final rightDistance = (rightWeek - widget.displayWeek).abs();
    if (leftDistance != rightDistance) {
      return leftDistance.compareTo(rightDistance);
    }
    if (leftWeek != rightWeek) {
      return leftWeek.compareTo(rightWeek);
    }

    final leftDay = _ruleWeekday(left);
    final rightDay = _ruleWeekday(right);
    if (leftDay != rightDay) {
      return leftDay.compareTo(rightDay);
    }

    return _ruleStartLesson(left).compareTo(_ruleStartLesson(right));
  }

  int _ruleWeek(CourseChangeRule rule) {
    return rule.targetLesson?.week ?? rule.originalLesson?.week ?? 99;
  }

  int _ruleWeekday(CourseChangeRule rule) {
    return rule.targetLesson?.weekday ?? rule.originalLesson?.weekday ?? 99;
  }

  int _ruleStartLesson(CourseChangeRule rule) {
    return rule.targetLesson?.startLesson ??
        rule.originalLesson?.startLesson ??
        99;
  }

  Widget _buildNoticeCard(BuildContext context, CourseChangeNotice notice) {
    final cs = Theme.of(context).colorScheme;
    final rule = notice.rule;
    final pending = notice.isUnapplied;
    final roomOnly = isRoomOnlyChange(rule);

    final typeLabel = roomOnly
        ? '换教室'
        : switch (rule.type) {
            CourseChangeType.reschedule => '调课',
            CourseChangeType.cancel => '停课',
            CourseChangeType.makeup => '补课',
          };
    final courseName = (rule.courseName ?? '').trim();
    final teacher = (rule.teacherName ?? '').trim();
    final weekText = _formatNoticeWeek(notice);
    final rawMessage = (notice.rawMessage ?? '').trim();

    return Container(
      // 按提醒对象区分，切换分段时「查看原文」的展开态不串到另一组卡片。
      key: ObjectKey(notice),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: pending ? null : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: pending ? Border.all(color: cs.outlineVariant) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppStatusTag(
                pending ? '$typeLabel · 待确认' : typeLabel,
                tone: pending
                    ? AppStatusTone.attention
                    : AppStatusTone.positive,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  courseName.isEmpty ? '课程调整' : courseName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (teacher.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(teacher, style: context.appText.meta),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ..._buildChangeBody(context, rule, weekText, roomOnly: roomOnly),
          if (pending) ...[
            const SizedBox(height: 6),
            Text(
              rule.termContext == null ? '学期未标注，请核对原文' : '课表未显示',
              style: context.appText.meta,
            ),
          ],
          if (rawMessage.isNotEmpty) _RawMessageToggle(message: rawMessage),
        ],
      ),
    );
  }

  List<Widget> _buildChangeBody(
    BuildContext context,
    CourseChangeRule rule,
    String weekText, {
    required bool roomOnly,
  }) {
    final cs = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium!
        .copyWith(height: 1.35, color: cs.onSurface);
    final struck = base.copyWith(
      color: cs.outline,
      decoration: TextDecoration.lineThrough,
      decorationColor: cs.outline,
    );
    final original = rule.originalLesson;
    final target = rule.targetLesson;
    final oldRoom = (rule.originalClassroom ?? '').trim();
    final newRoom = (rule.classroom ?? '').trim();

    if (roomOnly) {
      final slot = _formatSlot(target ?? original, weekText);
      return [
        Text.rich(
          TextSpan(
            style: base,
            children: [
              TextSpan(text: '$slot  '),
              if (oldRoom.isNotEmpty) ...[
                TextSpan(text: oldRoom, style: struck),
                const TextSpan(text: ' → '),
              ] else
                const TextSpan(text: '改到 '),
              TextSpan(
                text: newRoom,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ];
    }

    if (rule.type == CourseChangeType.cancel) {
      return [
        Text.rich(
          TextSpan(
            style: base,
            children: [
              TextSpan(
                text: _joinSlotRoom(_formatSlot(original, weekText), oldRoom),
                style: struck,
              ),
              const TextSpan(text: '  '),
              TextSpan(
                text: '停课',
                style: TextStyle(color: cs.error, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ];
    }

    final showOriginal =
        original != null || rule.type == CourseChangeType.reschedule;
    return [
      if (showOriginal)
        _ChangeLine(
          label: '原',
          labelStyle: context.appText.tag.copyWith(
            fontWeight: FontWeight.w400,
            color: cs.onSurfaceVariant,
          ),
          text: _joinSlotRoom(_formatSlot(original, weekText), oldRoom),
          textStyle: struck,
        ),
      if (showOriginal) const SizedBox(height: 4),
      _ChangeLine(
        label: rule.type == CourseChangeType.makeup ? '补' : '改',
        labelStyle: context.appText.tag.copyWith(color: cs.primary),
        text: _joinSlotRoom(
          _formatSlot(target, weekText),
          newRoom.isNotEmpty ? newRoom : oldRoom,
        ),
        textStyle: base.copyWith(fontWeight: FontWeight.w600),
      ),
    ];
  }

  static String _joinSlotRoom(String slot, String room) =>
      room.isEmpty ? slot : '$slot · $room';

  /// 通知覆盖的周次文本（多周合并为「第1-16周」）。
  String _formatNoticeWeek(CourseChangeNotice notice) {
    final raw = notice.rawMessage ?? '';
    final match = RegExp(r'第\s*([0-9\s,~\-周]+?)\s*周').firstMatch(raw);
    if (match != null) {
      final captured = match.group(1)!.replaceAll('周', '').trim();
      if (captured.isNotEmpty) {
        return '第$captured周';
      }
    }
    final range = notice.effectiveCourse?.weekRange.trim() ?? '';
    if (range.isNotEmpty) {
      return range.startsWith('第') ? range : '第$range';
    }
    final week =
        notice.rule.targetLesson?.week ?? notice.rule.originalLesson?.week;
    if (week != null) return '第$week周';
    return '';
  }

  /// 「周X a–b 节」；非本周（或未知当前周）时前缀周次「第N周 周X a–b 节」。
  String _formatSlot(CourseLessonSlot? slot, String weekText) {
    if (slot == null) return '时间待确认';
    final lessonRange = slot.startLesson == slot.endLesson
        ? '${slot.startLesson}'
        : '${slot.startLesson}–${slot.endLesson}';
    final weekday = slot.weekday >= 1 && slot.weekday <= 7
        ? scheduleWeekdayLabels[slot.weekday - 1]
        : '?';
    final text = '周$weekday $lessonRange 节';
    final week = weekText.isNotEmpty ? weekText : '第${slot.week}周';
    final currentWeek = widget.currentWeek;
    if (currentWeek != null && week == '第$currentWeek周') return text;
    return '$week $text';
  }
}

class _ChangeLine extends StatelessWidget {
  const _ChangeLine({
    required this.label,
    required this.labelStyle,
    required this.text,
    required this.textStyle,
  });

  final String label;
  final TextStyle labelStyle;
  final String text;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(width: 22, child: Text(label, style: labelStyle)),
        Expanded(child: Text(text, style: textStyle)),
      ],
    );
  }
}

/// 「查看原文」折叠区，默认收起。
class _RawMessageToggle extends StatefulWidget {
  const _RawMessageToggle({required this.message});

  final String message;

  @override
  State<_RawMessageToggle> createState() => _RawMessageToggleState();
}

class _RawMessageToggleState extends State<_RawMessageToggle> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _expanded ? '收起原文' : '查看原文',
                  style: context.appText.meta.copyWith(
                    fontWeight: FontWeight.w500,
                    color: cs.primary,
                  ),
                ),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: cs.primary,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              widget.message,
              style: context.appText.meta.copyWith(height: 1.4),
            ),
          ),
      ],
    );
  }
}
