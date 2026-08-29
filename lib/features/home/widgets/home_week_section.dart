import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../models/home_presentation.dart';
import 'home_card_container.dart';

/// Week Section：「本周」标题 + 周一~周日两列摘要 + 「查看完整课表」入口。
///
/// 摘要为课程节数与考试场次标注，整块可点跳转课表，无固定高度。
class HomeWeekSection extends StatelessWidget {
  const HomeWeekSection({
    super.key,
    required this.week,
    required this.onOpenSchedule,
  });

  final HomeWeekPresentation week;
  final VoidCallback onOpenSchedule;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    final accentColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    // 深色下 error 小字号偏灰，向白色提亮保持考试标注的警示可读性。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final examAccentColor = isDark
        ? Color.lerp(cs.error, Colors.white, 0.28)!
        : cs.error;
    final leftDays = week.days.take(4).toList(growable: false);
    final rightDays = week.days.skip(4).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Row(
            children: [
              Text(
                '本周',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: primaryTextColor,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: secondaryTextColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    week.weekLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        HomeCardContainer(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.cardPadding,
            vertical: 12,
          ),
          onTap: onOpenSchedule,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        for (final day in leftDays)
                          _buildDayRow(
                            day,
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor,
                            errorColor: examAccentColor,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      children: [
                        for (final day in rightDays)
                          _buildDayRow(
                            day,
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor,
                            errorColor: examAccentColor,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                height: 1,
                color: secondaryTextColor.withValues(alpha: 0.10),
              ),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Text(
                      '查看完整课表',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: accentColor,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.arrow_forward_ios,
                      size: 12,
                      color: secondaryTextColor,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDayRow(
    HomeWeekDaySummary day, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
    required Color errorColor,
  }) {
    final hasExam = day.examCount > 0;
    final hasCourse = day.courseCount > 0;
    final courseText = hasCourse ? '${day.courseCount} 节课' : '';
    final examText = hasExam ? '${day.examCount} 场考试' : '';
    final isEmpty = !hasCourse && !hasExam;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(
            day.dayLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: day.isToday ? FontWeight.w700 : FontWeight.w500,
              color: day.isToday ? primaryTextColor : secondaryTextColor,
            ),
          ),
          if (day.isToday) ...[
            const SizedBox(width: 4),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: primaryTextColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (hasCourse)
                    TextSpan(
                      text: courseText,
                      style: TextStyle(fontSize: 12, color: secondaryTextColor),
                    ),
                  if (hasCourse && hasExam)
                    TextSpan(
                      text: ' · ',
                      style: TextStyle(
                        fontSize: 12,
                        color: secondaryTextColor.withValues(alpha: 0.6),
                      ),
                    ),
                  if (hasExam)
                    TextSpan(
                      text: examText,
                      style: TextStyle(fontSize: 12, color: errorColor),
                    ),
                  if (isEmpty)
                    TextSpan(
                      text: '无课',
                      style: TextStyle(
                        fontSize: 12,
                        color: secondaryTextColor.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
