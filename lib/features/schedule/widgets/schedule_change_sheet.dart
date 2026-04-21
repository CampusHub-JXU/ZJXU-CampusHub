import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../schedule_change_rule.dart';
import '../schedule_constants.dart';

class ScheduleChangeSheet extends StatelessWidget {
  const ScheduleChangeSheet({
    super.key,
    required this.changeRules,
    required this.displayWeek,
    required this.scrollController,
  });

  final List<CourseChangeRule> changeRules;
  final int displayWeek;
  final ScrollController scrollController;


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sortedRules = [...changeRules]..sort(_compareRuleOrder);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(
              children: [
                Icon(
                  Icons.swap_horiz_rounded,
                  size: 20,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '调课提醒',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                Text(
                  '共 ${changeRules.length} 条',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已根据这些提醒自动修正课表显示',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
          Expanded(
            child: ListView.separated(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              physics: const ClampingScrollPhysics(),
              itemCount: sortedRules.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                return _buildRuleCard(context, sortedRules[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  int _compareRuleOrder(CourseChangeRule left, CourseChangeRule right) {
    final leftWeek = _ruleWeek(left);
    final rightWeek = _ruleWeek(right);
    final leftDistance = (leftWeek - displayWeek).abs();
    final rightDistance = (rightWeek - displayWeek).abs();
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

  Widget _buildRuleCard(BuildContext context, CourseChangeRule rule) {
    final cs = Theme.of(context).colorScheme;
    final tag = switch (rule.type) {
      CourseChangeType.reschedule => '调课',
      CourseChangeType.cancel => '停课',
      CourseChangeType.makeup => '补课',
    };
    final tagColor = switch (rule.type) {
      CourseChangeType.reschedule => const Color(0xFF1565C0),
      CourseChangeType.cancel => AppColors.error,
      CourseChangeType.makeup => const Color(0xFF2E7D32),
    };
    final courseName = (rule.courseName ?? '').trim();
    final meta = [
      if ((rule.teacherName ?? '').trim().isNotEmpty) rule.teacherName!.trim(),
      if ((rule.classroom ?? '').trim().isNotEmpty) rule.classroom!.trim(),
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: tagColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: tagColor,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  courseName.isEmpty ? '课程调整' : courseName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatRuleSummary(rule),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatRuleSummary(CourseChangeRule rule) {
    return switch (rule.type) {
      CourseChangeType.reschedule =>
        '${_formatSlot(rule.originalLesson)} -> ${_formatSlot(rule.targetLesson)}',
      CourseChangeType.cancel => '${_formatSlot(rule.originalLesson)} 停课',
      CourseChangeType.makeup => '${_formatSlot(rule.targetLesson)} 补课',
    };
  }

  String _formatSlot(CourseLessonSlot? slot) {
    if (slot == null) return '时间待确认';
    final lessonRange = slot.startLesson == slot.endLesson
        ? '${slot.startLesson}'
        : '${slot.startLesson}-${slot.endLesson}';
    final weekday = slot.weekday >= 1 && slot.weekday <= 7
        ? scheduleWeekdayLabels[slot.weekday - 1]
        : '?';
    return '第${slot.week}周 周$weekday 第$lessonRange节';
  }
}

