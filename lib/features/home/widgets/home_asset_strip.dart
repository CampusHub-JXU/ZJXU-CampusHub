import 'package:flutter/material.dart';

import '../../../core/theme/app_theme_controller.dart';
import '../../../core/theme/app_typography.dart';
import '../models/home_asset_state.dart';
import '../models/home_presentation.dart';

/// 无框资产行：校园卡余额 + 宿舍电费，左对齐并排、无分隔线。
///
/// 直接坐在页面背景上，无卡片底、无边框、无按钮——付款码 / 充值动作
/// 收敛到功能区瓦片与对应页面。层级靠 typography 建立且刻意低于 Hero：
/// 数值 18sp w600 只做「顺手扫一眼」的次级信息。只有低电量以 error
/// 圆点 + error 数值双通道达意；校园卡余额（含低余额）一律用常规色。
///
/// 两项状态彼此独立（[HomeStatusPresentation.campusCardState] /
/// [HomeStatusPresentation.electricityState]），一项失败 / 刷新不影响另一项。
/// 只有真实请求在途才显示小转圈（`state.isBusy`：`loading` / `refreshing`），
/// 「准备中 / 待登录 / 恢复中」是静态文案（不假装加载）；系统「移除动画」时
/// 转圈降级为静态提示。获取失败（无缓存）时整行点击为受控重试；其余状态保持
/// 既有的进入对应详情页导航。
class HomeAssetStrip extends StatelessWidget {
  const HomeAssetStrip({
    super.key,
    required this.status,
    required this.onCampusCardTap,
    required this.onElectricityTap,
    this.onCampusCardRetry,
    this.onElectricityRetry,
  });

  final HomeStatusPresentation status;
  final VoidCallback onCampusCardTap;
  final VoidCallback onElectricityTap;

  /// 获取失败（无可展示值）时资产行整行的受控重试回调；为空时失败态仍走导航。
  final VoidCallback? onCampusCardRetry;
  final VoidCallback? onElectricityRetry;

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
          child: _AssetZone(
            label: '校园卡',
            semanticsLabel: '校园卡余额',
            state: status.campusCardState,
            isLow: false,
            format: (value) => '¥$value',
            onTap: onCampusCardTap,
            onRetry: onCampusCardRetry,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
        ),
        const SizedBox(width: 36),
        Flexible(
          child: _AssetZone(
            label: '宿舍电费',
            semanticsLabel: '宿舍电费',
            state: status.electricityState,
            isLow: status.lowElectricity,
            format: (value) => '$value 度',
            onTap: onElectricityTap,
            onRetry: onElectricityRetry,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
          ),
        ),
      ],
    );
  }
}

/// 单项资产区：标签 + 状态值 + 小转圈 + 箭头，整块可点。
class _AssetZone extends StatelessWidget {
  const _AssetZone({
    required this.label,
    required this.semanticsLabel,
    required this.state,
    required this.isLow,
    required this.format,
    required this.onTap,
    required this.onRetry,
    required this.primaryTextColor,
    required this.secondaryTextColor,
  });

  final String label;

  /// 语义播报前缀（如「校园卡余额」），与可见短标签区分。
  final String semanticsLabel;
  final HomeAssetState state;
  final bool isLow;

  /// 把就绪值格式化成展示文本（含单位 / 货币符号）。
  final String Function(String value) format;
  final VoidCallback onTap;
  final VoidCallback? onRetry;
  final Color primaryTextColor;
  final Color secondaryTextColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final phase = state.phase;
    final hasValue = state.hasValue;
    // 失败（无缓存）时的受控重试优先；未提供回调则维持导航。
    final retryable = phase == HomeAssetPhase.error && onRetry != null;
    final effectiveOnTap = retryable ? onRetry! : onTap;
    final placeholder = !hasValue;
    final valueColor = placeholder
        ? (phase == HomeAssetPhase.error ? cs.error : secondaryTextColor)
        : isLow
        ? cs.error
        : primaryTextColor;
    final text = _displayText();

    return Semantics(
      button: true,
      // 内层 InkWell 关闭自身语义，这里补上等价的 tap 动作，避免无障碍
      // 服务只播报余额却无法激活；同时排除子文本语义，保持单节点播报。
      label: _semanticsText(),
      excludeSemantics: true,
      onTap: effectiveOnTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: effectiveOnTap,
          excludeFromSemantics: true,
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
                        style: context.appText.secondary.copyWith(
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
                          text,
                          style: textTheme.titleMedium!.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: valueColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (state.isBusy) ...[
                        const SizedBox(width: 6),
                        _AssetBusyIndicator(color: secondaryTextColor),
                      ],
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

  /// 字体 / 单位一致的展示文本：就绪 / 刷新态显示真实值，其余为状态文案。
  String _displayText() {
    switch (state.phase) {
      case HomeAssetPhase.ready:
      case HomeAssetPhase.refreshing:
        return format(state.value ?? '');
      case HomeAssetPhase.loading:
        return '获取中';
      case HomeAssetPhase.preparing:
        // 还没发起请求：中性占位（次要色），不声称「获取中」。
        return '--';
      case HomeAssetPhase.recovering:
        return '正在恢复';
      case HomeAssetPhase.waiting:
        return '待登录';
      case HomeAssetPhase.error:
        return '获取失败';
      case HomeAssetPhase.notConfigured:
        return '未设置';
    }
  }

  /// 每个状态各自准确的播报文案，不能再让所有无数据状态都读作「未获取」。
  String _semanticsText() {
    switch (state.phase) {
      case HomeAssetPhase.ready:
        return '$semanticsLabel ${format(state.value ?? '')}';
      case HomeAssetPhase.refreshing:
        return '$semanticsLabel ${format(state.value ?? '')}，正在刷新';
      case HomeAssetPhase.loading:
        return '$semanticsLabel正在获取';
      case HomeAssetPhase.preparing:
        return '$semanticsLabel尚未获取';
      case HomeAssetPhase.recovering:
        return '$semanticsLabel正在恢复登录';
      case HomeAssetPhase.waiting:
        return '$semanticsLabel待登录';
      case HomeAssetPhase.error:
        return '$semanticsLabel获取失败，点按重试';
      case HomeAssetPhase.notConfigured:
        return '$semanticsLabel未设置';
    }
  }
}

/// 小转圈：仅真实请求在途时出现；系统「移除动画」时降级为静态小圆点，
/// 既表达「正在进行」又不引入持续动画。
class _AssetBusyIndicator extends StatelessWidget {
  const _AssetBusyIndicator({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    }
    return SizedBox(
      width: 12,
      height: 12,
      child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
    );
  }
}
