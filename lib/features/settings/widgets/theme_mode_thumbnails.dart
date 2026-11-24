import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_preferences_controller.dart';
import '../../../core/theme/app_typography.dart';

/// 主题模式三段式紧凑选择器（跟随系统 / 浅色 / 深色）。
class ThemeModeThumbnails extends StatelessWidget {
  const ThemeModeThumbnails({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final AppThemePreference selected;
  final ValueChanged<AppThemePreference> onChanged;

  static const _items =
      <
        ({
          AppThemePreference mode,
          String label,
          IconData icon,
          IconData selectedIcon,
        })
      >[
        (
          mode: AppThemePreference.system,
          label: '跟随系统',
          icon: Icons.brightness_auto_outlined,
          selectedIcon: Icons.brightness_auto,
        ),
        (
          mode: AppThemePreference.light,
          label: '浅色',
          icon: Icons.light_mode_outlined,
          selectedIcon: Icons.light_mode,
        ),
        (
          mode: AppThemePreference.dark,
          label: '深色',
          icon: Icons.dark_mode_outlined,
          selectedIcon: Icons.dark_mode,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;

    final trackColor = cs.surfaceContainerHigh;
    final thumbColor = isDark
        ? Color.alphaBlend(
            cs.onSurface.withValues(alpha: 0.16),
            cs.surfaceContainerHighest,
          )
        : cs.surfaceContainerLowest;

    final selectedIndex = _items
        .indexWhere((item) => item.mode == selected)
        .clamp(0, _items.length - 1);
    final alignmentX = -1.0 + selectedIndex * 1.0;

    return AppTextScaleGuard.chrome(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: trackColor,
          shape: RoundedSuperellipseBorder(borderRadius: AppRadius.cardBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedAlign(
                  alignment: AlignmentDirectional(alignmentX, 0),
                  duration: duration,
                  curve: AppMotion.standard,
                  child: FractionallySizedBox(
                    widthFactor: 1 / _items.length,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: thumbColor,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final item in _items)
                    Expanded(
                      child: _ModeSegment(
                        label: item.label,
                        icon: item.icon,
                        selectedIcon: item.selectedIcon,
                        selected: selected == item.mode,
                        onTap: () => onChanged(item.mode),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = selected ? cs.primary : cs.onSurfaceVariant;
    final textColor = selected ? cs.onSurface : cs.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? selectedIcon : icon,
                    size: 17,
                    color: iconColor,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: AppChromeType.segment.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                    ),
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
