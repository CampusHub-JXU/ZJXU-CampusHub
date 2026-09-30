import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';

/// 横幅色调，只映射 ColorScheme 角色。
enum AppBannerTone {
  /// 中性提示（缓存过期、数据来自缓存）：`surfaceContainerHigh`。
  neutral,

  /// 需要用户处理（认证失效、刷新失败）：`errorContainer`。
  error,
}

/// 页内细横幅：图标 + 一句话 + 可选动作按钮，贴在列表 / 读数上方。
///
/// 统一各页自写的 `_AuthStaleBanner`、电费错误条、畅行错误条等
/// （docs/ui-unification-plan.md §5）。用于「保留旧数据，同时告诉用户哪里
/// 不对」；整页出错仍用 `AppErrorView`。
class AppBanner extends StatelessWidget {
  const AppBanner({
    super.key,
    required this.message,
    this.icon,
    this.tone = AppBannerTone.neutral,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData? icon;
  final AppBannerTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      AppBannerTone.neutral => (cs.surfaceContainerHigh, cs.onSurface),
      AppBannerTone.error => (cs.errorContainer, cs.onErrorContainer),
    };
    final iconColor = tone == AppBannerTone.neutral ? cs.error : foreground;
    final label = actionLabel;
    return Material(
      color: background,
      shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 10, label == null ? 14 : 6, 10),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                message,
                style: context.appText.secondary.copyWith(color: foreground),
              ),
            ),
            if (label != null && onAction != null) ...[
              const SizedBox(width: AppSpacing.sm),
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: tone == AppBannerTone.error
                      ? foreground
                      : cs.primary,
                ),
                child: Text(label),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
