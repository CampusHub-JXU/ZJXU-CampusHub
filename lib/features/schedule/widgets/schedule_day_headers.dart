import 'package:flutter/material.dart';

import '../../../core/semester/semester_calendar.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../schedule_constants.dart';

class ScheduleDayHeaders extends StatelessWidget {
  const ScheduleDayHeaders({
    super.key,
    required this.slotColumnWidth,
    required this.dayColumnWidth,
    required this.currentWeek,
    required this.isCurrentWeek,
    this.showNotStartedBadge = false,
  });

  final double slotColumnWidth;
  final double dayColumnWidth;
  final int currentWeek;
  final bool isCurrentWeek;

  /// 第 1 周且当前不存在"本周"（未开学）时，周徽标显示"未开学"。
  final bool showNotStartedBadge;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final today = DateTime.now().weekday;
    // 一周以周一为起点，日期必须与真实星期对齐。
    final weekStartDate = SemesterCalendar.instance.weekStartFor(currentWeek);

    return Container(
      // 头部与课表网格之间用一条发丝线分层，日期/周次层级更清晰。
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.35),
            width: 0.7,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: slotColumnWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '$scheduleTermLabelPrefix$currentWeek$scheduleWeekLabelSuffix',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isCurrentWeek
                      ? scheduleCurrentWeekLabel
                      : showNotStartedBadge
                      ? scheduleNotStartedLabel
                      : scheduleNonCurrentWeekLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          for (int i = 0; i < scheduleWeekdayLabels.length; i++)
            Builder(
              builder: (context) {
                final date = weekStartDate.add(Duration(days: i));
                final isToday = isCurrentWeek && (i + 1) == today;

                return SizedBox(
                  width: dayColumnWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isToday ? cs.primary : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadius.badge),
                        ),
                        child: Text(
                          '${date.day}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isToday
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isToday ? cs.onPrimary : cs.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '周${scheduleWeekdayLabels[i]}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isToday
                              ? FontWeight.w700
                              : FontWeight.normal,
                          color: isToday ? cs.primary : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
