import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../models/home_presentation.dart';
import 'home_card_container.dart';

/// 高频资产状态条：一行双分区（校园卡余额 + 付款码 | 宿舍电费 + 查看）。
///
/// 单一 surface 容器（内容层，无真实模糊），无固定高度；
/// 低电量 / 低余额时数值转 error 色并附警示图标（图标 + 颜色 + 文案同达意）。
class HomeStatusStrip extends StatelessWidget {
  const HomeStatusStrip({
    super.key,
    required this.status,
    required this.onCampusCardTap,
    required this.onPaymentTap,
    required this.onElectricityTap,
  });

  final HomeStatusPresentation status;
  final Future<void> Function() onCampusCardTap;
  final Future<void> Function() onPaymentTap;
  final Future<void> Function() onElectricityTap;

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

    return HomeCardContainer(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.cardPadding,
        vertical: 12,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _buildCampusCardZone(
                context,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor,
                accentColor: accentColor,
              ),
            ),
            Container(
              width: 1,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              color: secondaryTextColor.withValues(alpha: 0.18),
            ),
            Expanded(
              child: _buildElectricityZone(
                context,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCampusCardZone(
    BuildContext context, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
    required Color accentColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final valueColor = status.lowBalance ? cs.error : primaryTextColor;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.chip),
        onTap: () => onCampusCardTap(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '校园卡',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: secondaryTextColor,
                  ),
                ),
                if (status.lowBalance) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.warning_amber_rounded, size: 14, color: cs.error),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              status.hasCampusCardData ? '¥${status.campusCardBalance}' : '--',
              style: TextStyle(
                fontSize: 22,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: valueColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            _buildActionChip(
              context,
              icon: Icons.qr_code_2_rounded,
              label: '付款码',
              iconColor: accentColor,
              textColor: primaryTextColor,
              onTap: () => onPaymentTap(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildElectricityZone(
    BuildContext context, {
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final valueColor = status.lowElectricity ? cs.error : primaryTextColor;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.chip),
        onTap: () => onElectricityTap(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '宿舍电费',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: secondaryTextColor,
                  ),
                ),
                if (status.lowElectricity) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.warning_amber_rounded, size: 14, color: cs.error),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              status.hasElectricityData ? '${status.dormElectricity} 度' : '--',
              style: TextStyle(
                fontSize: 22,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: valueColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  Text(
                    '查看',
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
          ],
        ),
      ),
    );
  }

  Widget _buildActionChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color iconColor,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.input),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 64, minHeight: 44),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.input),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
