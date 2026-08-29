import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../models/home_presentation.dart';

/// 「常用」区：一行高频入口（付款码 / 课表 / 成绩 / 图书馆等）+
/// 「全部校园服务」行。
///
/// 入口横向排列，超出宽度时可横向滚动；每项点击区 ≥ 44×44，
/// 无固定高度、随文字缩放自然增高。
class HomeQuickActions extends StatelessWidget {
  const HomeQuickActions({
    super.key,
    required this.actions,
    required this.onActionTap,
    required this.onAllServicesTap,
  });

  final List<HomeQuickActionPresentation> actions;
  final ValueChanged<HomeQuickActionPresentation> onActionTap;
  final VoidCallback onAllServicesTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '常用',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: primaryTextColor,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final action in actions)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _buildActionItem(
                    context,
                    action,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.chip),
            onTap: onAllServicesTap,
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  Text(
                    '全部校园服务',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
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
          ),
        ),
      ],
    );
  }

  Widget _buildActionItem(
    BuildContext context,
    HomeQuickActionPresentation action, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final accentColor = AppThemeController.instance.resolveIconColor(
      context,
      action.accentColor ?? cs.primary,
    );
    return SizedBox(
      width: 76,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.tile),
          onTap: () => onActionTap(action),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.badge + 2),
                  ),
                  child: Icon(action.icon, size: 22, color: accentColor),
                ),
                const SizedBox(height: 6),
                Text(
                  action.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: primaryTextColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
