import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../shared/widgets/app_icon_badge.dart';

import 'home_card_container.dart';

class HomeMoreServicesCard extends StatelessWidget {
  const HomeMoreServicesCard({super.key, required this.onTap});

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
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    return HomeCardContainer(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          AppIconBadge(
            icon: Icons.apps_rounded,
            accentColor: cs.primary,
            size: AppIconBadgeSize.small,
            backgroundAlpha: 0.1,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '更多服务',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: primaryTextColor,
              ),
            ),
          ),
          Icon(Icons.arrow_forward_ios, size: 12, color: secondaryTextColor),
        ],
      ),
    );
  }
}
