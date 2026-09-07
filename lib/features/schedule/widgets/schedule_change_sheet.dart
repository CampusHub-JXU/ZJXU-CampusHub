import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../schedule_change_rule.dart';
import '../schedule_constants.dart';

/// 课表调整与换教室提醒底部抽屉。
///
/// 视觉与交互规范：
/// - 明确区分「当前课表已体现」（绿色标签）与「学期未确认/未体现」（橙色标签），
///   不误称所有提醒都已自动应用或自动修改课表。
/// - 详细展示：课程名称、时间周次（多周通知合并为一条并显示真实周次跨度）、旧教室 → 新教室、任课教师及通知原文。
/// - 结构清晰：已体现的当前提醒置顶展示；未确认学期的候选提醒支持折叠收起，避免往期无学期标记通知混杂刷屏。
class ScheduleChangeSheet extends StatefulWidget {
  const ScheduleChangeSheet({
    super.key,
    this.notices = const [],
    this.changeRules = const [],
    required this.displayWeek,
    required this.scrollController,
  });

  final List<CourseChangeNotice> notices;
  final List<CourseChangeRule> changeRules;
  final int displayWeek;
  final ScrollController scrollController;

  @override
  State<ScheduleChangeSheet> createState() => _ScheduleChangeSheetState();
}

class _ScheduleChangeSheetState extends State<ScheduleChangeSheet> {
  /// 待确认提醒的展开状态（若存在当前已体现提醒，默认折叠；若仅有待确认提醒，默认展开）。
  bool _unappliedExpanded = false;

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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final notices = _effectiveNotices;

    final reflected = notices.where((n) => n.isReflected).toList()
      ..sort((a, b) => _compareRuleOrder(a.rule, b.rule));
    final unapplied = notices.where((n) => n.isUnapplied).toList()
      ..sort((a, b) => _compareRuleOrder(a.rule, b.rule));

    // 若无已体现项，默认展开待确认项以便用户查阅
    final showUnappliedExpanded = reflected.isEmpty || _unappliedExpanded;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Icon(Icons.swap_horiz_rounded, size: 22, color: cs.primary),
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
                  '共 ${notices.length} 条',
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
                '绿色标签为当前课表已体现条目；学期未确认的提醒请参考原文核对',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              physics: const ClampingScrollPhysics(),
              children: [
                if (reflected.isNotEmpty) ...[
                  _buildSectionHeader(
                    context,
                    title: '当前课表已体现 (${reflected.length})',
                    icon: Icons.check_circle_outline_rounded,
                    iconColor: const Color(0xFF2E7D32),
                  ),
                  const SizedBox(height: 8),
                  for (final notice in reflected) ...[
                    _buildNoticeCard(context, notice),
                    const SizedBox(height: 10),
                  ],
                ],
                if (unapplied.isNotEmpty) ...[
                  if (reflected.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: () {
                        setState(() {
                          _unappliedExpanded = !_unappliedExpanded;
                        });
                      },
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.help_outline_rounded,
                              size: 18,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '待确认提醒 (${unapplied.length})',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Icon(
                              showUnappliedExpanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 20,
                              color: cs.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ] else ...[
                    _buildSectionHeader(
                      context,
                      title: '待确认提醒 (${unapplied.length})',
                      icon: Icons.help_outline_rounded,
                      iconColor: const Color(0xFFE65100),
                    ),
                  ],
                  if (showUnappliedExpanded) ...[
                    const SizedBox(height: 8),
                    for (final notice in unapplied) ...[
                      _buildNoticeCard(context, notice),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color iconColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2, top: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final rule = notice.rule;

    // 类型标签：换教室 / 调课 / 停课 / 补课
    final isClassroomChange =
        rule.type == CourseChangeType.reschedule &&
        (rule.originalClassroom != null || rule.classroom != null);
    final typeLabel = isClassroomChange
        ? '换教室'
        : switch (rule.type) {
            CourseChangeType.reschedule => '调课',
            CourseChangeType.cancel => '停课',
            CourseChangeType.makeup => '补课',
          };
    final typeColor = switch (rule.type) {
      CourseChangeType.reschedule => cs.primary,
      CourseChangeType.cancel => cs.error,
      CourseChangeType.makeup => cs.tertiary,
    };

    // 状态标签色彩与文案：明确区分「当前课表已体现」与「学期未确认 / 未体现」
    final statusBgColor = notice.isReflected
        ? (isDark ? const Color(0x334CAF50) : const Color(0xFFE8F5E9))
        : (isDark ? const Color(0x33FF9800) : const Color(0xFFFFF3E0));
    final statusTextColor = notice.isReflected
        ? (isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32))
        : (isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100));

    final statusText = notice.isReflected
        ? '当前课表已体现'
        : (rule.termContext == null ? '学期未确认 · 未应用' : '当前课表未体现');

    final courseName = (rule.courseName ?? '').trim();
    final meta = [
      if ((rule.teacherName ?? '').trim().isNotEmpty) rule.teacherName!.trim(),
      if ((rule.classroom ?? '').trim().isNotEmpty) rule.classroom!.trim(),
    ].join(' · ');

    final hasOldClassroom =
        rule.originalClassroom != null && rule.originalClassroom!.isNotEmpty;
    final hasNewClassroom =
        rule.classroom != null && rule.classroom!.isNotEmpty;

    final weekDisplay = _formatNoticeWeek(notice);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 类型 Tag
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  typeLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: typeColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 状态 Tag（已体现 vs 未应用/未确认）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: statusBgColor,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: statusTextColor,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                weekDisplay,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            courseName.isEmpty ? '课程调整' : courseName,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatRuleSummary(rule, weekText: weekDisplay),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          // 教室流转明确标注（旧 → 新）
          if (hasOldClassroom && hasNewClassroom) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.meeting_room_outlined, size: 14, color: cs.primary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '教室变更：${rule.originalClassroom} → ${rule.classroom}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (hasNewClassroom) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.meeting_room_outlined, size: 14, color: cs.primary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '上课教室：${rule.classroom}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              meta,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
          // 原文留档（原文展示供核对，无歧义）
          if (notice.rawMessage != null && notice.rawMessage!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '原文：${notice.rawMessage!.trim()}',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatNoticeWeek(CourseChangeNotice notice) {
    final raw = notice.rawMessage ?? '';
    final match = RegExp(r'第\s*([0-9\s,~\-周]+?)\s*周').firstMatch(raw);
    if (match != null) {
      final captured = match.group(1)!.replaceAll('周', '').trim();
      if (captured.isNotEmpty) {
        return '第$captured周';
      }
    }
    if (notice.effectiveCourse != null &&
        notice.effectiveCourse!.weekRange.isNotEmpty) {
      return notice.effectiveCourse!.weekRange;
    }
    final week =
        notice.rule.targetLesson?.week ?? notice.rule.originalLesson?.week;
    if (week != null) return '第$week周';
    return '周次待确认';
  }

  String _formatRuleSummary(CourseChangeRule rule, {String? weekText}) {
    return switch (rule.type) {
      CourseChangeType.reschedule =>
        '${_formatSlot(rule.originalLesson, weekText: weekText)} -> ${_formatSlot(rule.targetLesson, weekText: weekText)}',
      CourseChangeType.cancel =>
        '${_formatSlot(rule.originalLesson, weekText: weekText)} 停课',
      CourseChangeType.makeup =>
        '${_formatSlot(rule.targetLesson, weekText: weekText)} 补课',
    };
  }

  String _formatSlot(CourseLessonSlot? slot, {String? weekText}) {
    if (slot == null) return '时间待确认';
    final lessonRange = slot.startLesson == slot.endLesson
        ? '${slot.startLesson}'
        : '${slot.startLesson}-${slot.endLesson}';
    final weekday = slot.weekday >= 1 && slot.weekday <= 7
        ? scheduleWeekdayLabels[slot.weekday - 1]
        : '?';
    final week = weekText ?? '第${slot.week}周';
    return '$week 周$weekday 第$lessonRange节';
  }
}
