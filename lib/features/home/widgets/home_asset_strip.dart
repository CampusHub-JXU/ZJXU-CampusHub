import 'package:flutter/material.dart';

import '../../../core/theme/app_theme_controller.dart';
import '../models/home_presentation.dart';

/// 无框资产行：校园卡余额 + 宿舍电费，左对齐并排、无分隔线。
///
/// 直接坐在页面背景上，无卡片底、无边框、无按钮——付款码 / 充值动作
/// 收敛到功能区瓦片与对应页面。层级靠 typography 建立且刻意低于 Hero：
/// 数值 18sp w600 只做「顺手扫一眼」的次级信息。只有低电量以 error
/// 圆点 + error 数值双通道达意；校园卡余额（含低余额）一律用常规色。
class HomeAssetStrip extends StatelessWidget {
  const HomeAssetStrip({
    super.key,
    required this.status,
    required this.onCampusCardTap,
    required this.onElectricityTap,
  });

  final HomeStatusPresentation status;
  final VoidCallback onCampusCardTap;
  final VoidCallback onElectricityTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    // 两区按内容宽度左对齐并排（loose Flexible 防长数值溢出），
    // 不再等分撑满，也不画中间分隔线。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: _buildAssetZone(
            context,
            label: '校园卡',
            value: status.hasCampusCardData
                ? '¥${status.campusCardBalance}'
                : '--',
            // 低余额不再强调：校园卡恒定 false，数值用常规色。
            isLow: false,
            hasData: status.hasCampusCardData,
            semanticsLabel: status.hasCampusCardData
                ? '校园卡余额 ¥${status.campusCardBalance}'
                : '校园卡余额未获取',
            onTap: onCampusCardTap,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
        ),
        const SizedBox(width: 36),
        Flexible(
          child: _buildAssetZone(
            context,
            label: '宿舍电费',
            value: status.hasElectricityData
                ? '${status.dormElectricity} 度'
                : '--',
            isLow: status.lowElectricity,
            hasData: status.hasElectricityData,
            semanticsLabel: status.hasElectricityData
                ? '宿舍电费 ${status.dormElectricity} 度'
                : '宿舍电费未获取',
            onTap: onElectricityTap,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
        ),
      ],
    );
  }

  Widget _buildAssetZone(
    BuildContext context, {
    required String label,
    required String value,
    required bool isLow,
    required bool hasData,
    required String semanticsLabel,
    required VoidCallback onTap,
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 数值异常只有低电量用 error 色；未获取（'--'）降为次级灰。
    final valueColor = !hasData
        ? secondaryTextColor
        : isLow
        ? cs.error
        : primaryTextColor;
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLow) ...[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: cs.error,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        style: textTheme.labelMedium!.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          value,
                          style: textTheme.titleMedium!.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: valueColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: cs.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
