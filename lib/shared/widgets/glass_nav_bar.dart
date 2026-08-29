import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import 'glass_container.dart';

/// 悬浮矩形玻璃底栏（dock）。
///
/// Apple 风格的 floating dock：整宽毛玻璃圆角矩形悬浮于内容之上，圆角
/// 刻意收紧（[AppRadius.dock]）保持矩形倾向；选中项为圆角矩形指示器。
/// 整屏仅此一个 BackdropFilter 层。
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.destinations,
    required this.currentIndex,
    required this.onDestinationSelected,
  });

  final List<GlassNavBarDestination> destinations;
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GlassContainer(
      tier: GlassTier.nav,
      borderRadius: BorderRadius.circular(AppRadius.dock),
      child: SizedBox(
        height: 68,
        child: Row(
          children: [
            for (var i = 0; i < destinations.length; i++)
              Expanded(
                child: _NavDestination(
                  destination: destinations[i],
                  selected: i == currentIndex,
                  accent: cs.primary,
                  onTap: () => onDestinationSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GlassNavBarDestination {
  const GlassNavBarDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _NavDestination extends StatelessWidget {
  const _NavDestination({
    required this.destination,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final GlassNavBarDestination destination;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = selected ? accent : cs.onSurfaceVariant;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: ShapeDecoration(
            color: selected ? accent.withValues(alpha: 0.16) : null,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  key: ValueKey(selected),
                  size: 24,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                destination.label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.0,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
