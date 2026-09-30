import 'package:flutter/material.dart';

import '../../core/theme/app_typography.dart';

/// 状态标签的语义色调，只映射 ColorScheme 角色（design-guidelines §4.6：
/// 不写死绿 / 橙等颜色值，深色模式与动态色下自动适配）。
enum AppStatusTone {
  /// 中性信息（分类、学期）：`surfaceContainerHighest`。
  neutral,

  /// 正常 / 进行中 / 即将到来：`secondaryContainer`。
  positive,

  /// 提醒 / 待确认 / 重修：`tertiaryContainer`。
  attention,

  /// 异常 / 已过期 / 已满：`errorContainer`。
  danger,
}

/// 统一的状态标签：pill 形状 + `tag` 字体（11 w600）。
///
/// 取代各页自写的 `_InfoChip` / `_TinyBadge` / 倒计时 chip 等（圆角 4 / 6 /
/// 8 / 10 / 999 并存的那一批，docs/ui-unification-plan.md §2.3）。
class AppStatusTag extends StatelessWidget {
  const AppStatusTag(
    this.label, {
    super.key,
    this.tone = AppStatusTone.neutral,
  });

  final String label;
  final AppStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      AppStatusTone.neutral => (
        cs.surfaceContainerHighest,
        cs.onSurfaceVariant,
      ),
      AppStatusTone.positive => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      AppStatusTone.attention => (cs.tertiaryContainer, cs.onTertiaryContainer),
      AppStatusTone.danger => (cs.errorContainer, cs.onErrorContainer),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: background,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          maxLines: 1,
          style: context.appText.tag.copyWith(color: foreground),
        ),
      ),
    );
  }
}
