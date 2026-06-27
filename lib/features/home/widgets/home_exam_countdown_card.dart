import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../exam/exam_model.dart';
import 'home_card_container.dart';

class HomeExamCountdownCard extends StatelessWidget {
  const HomeExamCountdownCard({
    super.key,
    required this.exam,
    required this.onTap,
  });

  final ExamEntry? exam;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HomeTextColorMode>(
      valueListenable: AppThemeController.instance.homeTextColorMode,
      builder: (context, _, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    final currentExam = exam;

    return HomeCardContainer(
      height: 126,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: AppIconBadge(
              icon: Icons.quiz_outlined,
              accentColor: iconColor,
              size: AppIconBadgeSize.small,
              backgroundAlpha: 0.1,
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '考试安排',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: primaryTextColor,
                  ),
                ),
                const SizedBox(height: 2),
                if (currentExam != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          currentExam.courseName,
                          style: TextStyle(
                            fontSize: 13,
                            color: secondaryTextColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _countdownText(currentExam),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: primaryTextColor,
                        ),
                      ),
                    ],
                  ),
                ] else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '暂无考试信息',
                          style: TextStyle(
                            fontSize: 13,
                            color: secondaryTextColor,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        size: 14,
                        color: secondaryTextColor,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _countdownText(ExamEntry exam) {
    final days = exam.daysUntil;
    if (days < 0) return '已结束';
    if (days == 0) return '今天';
    if (days == 1) return '明天';
    return '$days天后';
  }
}
