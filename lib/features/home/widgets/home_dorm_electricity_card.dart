import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../app/theme.dart';
import 'home_card_container.dart';

class HomeDormElectricityCard extends StatelessWidget {
  const HomeDormElectricityCard({
    super.key,
    required this.dormElectricity,
    required this.onTap,
  });

  final String dormElectricity;
  final Future<void> Function() onTap;

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
      AppColors.success,
    );
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    return HomeCardContainer(
      height: 126,
      onTap: () => onTap(),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(Icons.bolt_outlined, color: iconColor, size: 20),
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '宿舍电费',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: primaryTextColor,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        '剩余 $dormElectricity 度',
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
}
