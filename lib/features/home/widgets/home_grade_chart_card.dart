import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../grades/grades_model.dart';
import 'home_card_container.dart';

class HomeGradeChartCard extends StatelessWidget {
  const HomeGradeChartCard({
    super.key,
    required this.grades,
    required this.onTap,
  });

  final List<GradeEntry> grades;
  final VoidCallback onTap;

  double get _totalCredits =>
      grades.fold(0.0, (sum, g) => sum + (g.gpaPoints > 0 ? g.credits : 0));

  int get _courseCount => grades.length;

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

    return HomeCardContainer(
      height: 126,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: AppIconBadge(
              icon: Icons.school_outlined,
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
                  '成绩查询',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: primaryTextColor,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        grades.isEmpty
                            ? '暂无成绩数据'
                            : '${_compactNumber(_totalCredits)}学分 · $_courseCount门课',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: secondaryTextColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
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

  String _compactNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }
}
