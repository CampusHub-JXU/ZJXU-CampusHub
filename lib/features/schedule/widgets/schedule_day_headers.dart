import 'package:flutter/material.dart';

import '../../../core/semester/semester_calendar.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_surface_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/academic/schedule_constants.dart';

/// 课表表头：节次列上方是周次，右侧 7 列是「周几 + 日期」。
///
/// 设计系统 v2 · `O1` 微字阶：星期 `12/600`、日期 `10.5/400`，今天用
/// 品牌淡底胶囊 + 品牌色文字标记。表头与网格之间那条线是全 App 唯一
/// 允许的坐标辅助线之一（`AppSurfaces.matrixLine`）。
///
/// 「本周 / 非本周 / 未开学」不再挤在 30dp 的节次列里（挤不下且会把
/// 周次数字顶掉）——学期状态由 `ScheduleInfoBanner` 在页面顶部说明，
/// 非本周课程的角标由课程块自己标。
class ScheduleDayHeaders extends StatelessWidget {
  const ScheduleDayHeaders({
    super.key,
    required this.slotColumnWidth,
    required this.dayColumnWidth,
    required this.currentWeek,
    required this.isCurrentWeek,
  });

  final double slotColumnWidth;
  final double dayColumnWidth;
  final int currentWeek;
  final bool isCurrentWeek;

  @override
  Widget build(BuildContext context) {
    final surfaces = context.appSurfaces;
    final today = DateTime.now().weekday;
    // 一周以周一为起点，日期必须与真实星期对齐。
    final weekStartDate = SemesterCalendar.instance.weekStartFor(currentWeek);
    final weekAccent = isCurrentWeek ? surfaces.brand : surfaces.ink2;

    return Container(
      decoration: BoxDecoration(
        color: surfaces.card,
        border: Border(
          bottom: BorderSide(color: surfaces.matrixLine, width: 0.7),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: slotColumnWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$currentWeek',
                  textAlign: TextAlign.center,
                  style: AppScheduleType.slotIndex.copyWith(color: weekAccent),
                ),
                const SizedBox(height: 1),
                Text(
                  scheduleWeekLabelSuffix,
                  textAlign: TextAlign.center,
                  style: AppScheduleType.slotTime.copyWith(
                    color: surfaces.ink3,
                  ),
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
                        padding: EdgeInsets.symmetric(
                          horizontal: isToday ? 6 : 2,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: isToday
                              ? surfaces.brandTint
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadius.tag),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              scheduleWeekdayLabels[i],
                              maxLines: 1,
                              style: AppScheduleType.weekday.copyWith(
                                color: isToday ? surfaces.brand : surfaces.ink1,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              '${date.day}',
                              maxLines: 1,
                              style: AppScheduleType.date.copyWith(
                                color: isToday ? surfaces.brand : surfaces.ink2,
                                fontWeight: isToday
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
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
