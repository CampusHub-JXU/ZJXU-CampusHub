import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import 'glass_container.dart';

/// 贴底通栏液态玻璃底栏（flush bottom bar）。
///
/// 贴边、贴底通栏铺满并将背景自然延伸至系统底部手势区；保留克制的
/// 液态玻璃折射与上缘细分割线，选中态以顶部居中短指示线与字重/实体图标
/// 表达，不再使用悬浮药丸或圆角底块。
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

  static const double _barHeight = 58;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return GlassContainer(
      tier: GlassTier.nav,
      borderRadius: BorderRadius.zero,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: _barHeight,
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

class _NavDestination extends StatefulWidget {
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
  State<_NavDestination> createState() => _NavDestinationState();
}

class _NavDestinationState extends State<_NavDestination> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final accent = widget.accent;
    final color = selected ? accent : cs.onSurfaceVariant;
    // 系统「移除动画」时指示器与图标直接切换。
    final reduceMotion = AppMotion.reduced(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedContainer(
                duration: reduceMotion ? Duration.zero : AppMotion.quick,
                curve: AppMotion.standard,
                width: 20,
                height: 2,
                decoration: BoxDecoration(
                  color: selected ? accent : accent.withValues(alpha: 0),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(1),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: AnimatedScale(
              scale: (!reduceMotion && _pressed) ? 0.94 : 1.0,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 90),
              curve: AppMotion.standard,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected
                        ? widget.destination.selectedIcon
                        : widget.destination.icon,
                    size: 22,
                    color: color,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.destination.label,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.1,
                      letterSpacing: 0.1,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
