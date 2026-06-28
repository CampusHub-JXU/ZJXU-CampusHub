import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';

/// 定制下拉选择组件，替代原生 [DropdownButton]。
///
/// 使用 Overlay + AnimatedSwitcher 实现弹出菜单，避免原生样式的不一致。
/// 支持泛型 [T]，通过 [items] 提供选项，[value] 标记当前选中项。
class AppDropdown<T> extends StatefulWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expanded = false,
    this.prefixIcon,
    this.hint,
  });

  /// 当前选中值。为 `null` 时显示 [hint]。
  final T? value;

  /// 所有可选项。
  final List<AppDropdownItem<T>> items;

  /// 选中项变化回调。
  final ValueChanged<T?>? onChanged;

  /// 是否撑满父容器宽度。
  final bool expanded;

  /// 按钮左侧图标。
  final IconData? prefixIcon;

  /// 未选中时的占位文本。
  final String? hint;

  @override
  State<AppDropdown<T>> createState() => _AppDropdownState<T>();
}

/// 下拉菜单的一个选项。
class AppDropdownItem<T> {
  const AppDropdownItem({required this.value, required this.label, this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

class _AppDropdownState<T> extends State<AppDropdown<T>>
    with SingleTickerProviderStateMixin {
  late OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  final _buttonKey = GlobalKey();

  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _overlayEntry = null;
    _animController = AnimationController(
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, -0.08), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
        );
  }

  @override
  void dispose() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    }
    _animController.dispose();
    super.dispose();
  }

  AppDropdownItem<T>? get _selectedItem {
    if (widget.value == null) return null;
    return widget.items.where((item) => item.value == widget.value).firstOrNull;
  }

  void _toggleOverlay() {
    if (_isOpen) {
      _closeOverlay();
    } else {
      _openOverlay();
    }
  }

  void _openOverlay() {
    final overlay = Overlay.of(context);
    final renderBox =
        _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    final buttonSize = renderBox.size;
    final buttonRect =
        renderBox.localToGlobal(Offset.zero, ancestor: overlayBox) & buttonSize;
    final overlaySize = overlayBox.size;
    final cs = Theme.of(context).colorScheme;

    _overlayEntry = OverlayEntry(
      builder: (context) => _AppDropdownOverlay<T>(
        buttonRect: buttonRect,
        overlaySize: overlaySize,
        buttonWidth: buttonSize.width,
        items: widget.items,
        selectedValue: widget.value,
        colorScheme: cs,
        fadeAnim: _fadeAnim,
        slideAnim: _slideAnim,
        onItemSelected: (value) {
          _closeOverlay();
          widget.onChanged?.call(value);
        },
        onDismiss: _closeOverlay,
      ),
    );
    overlay.insert(_overlayEntry!);
    _animController.forward();
    setState(() => _isOpen = true);
  }

  void _closeOverlay({bool immediate = false}) {
    if (!_isOpen && _overlayEntry == null) return;
    if (immediate) {
      _animController.reset();
      _overlayEntry?.remove();
      _overlayEntry = null;
      if (mounted) setState(() => _isOpen = false);
      return;
    }
    _animController.reverse().then((_) {
      _overlayEntry?.remove();
      _overlayEntry = null;
    });
    if (mounted) setState(() => _isOpen = false);
  }

  @visibleForTesting
  void openOverlayForTest() => _openOverlay();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selectedItem = _selectedItem;
    final label = selectedItem?.label ?? widget.hint ?? '';
    final hasSelection = selectedItem != null;

    return _DropdownButton(
      key: _buttonKey,
      label: label,
      hasSelection: hasSelection,
      isOpen: _isOpen,
      prefixIcon: widget.prefixIcon,
      expanded: widget.expanded,
      colorScheme: cs,
      onTap: _toggleOverlay,
    );
  }
}

/// 下拉按钮部分。单独抽出以便测试。
class _DropdownButton extends StatelessWidget {
  const _DropdownButton({
    super.key,
    required this.label,
    required this.hasSelection,
    required this.isOpen,
    required this.prefixIcon,
    required this.expanded,
    required this.colorScheme,
    required this.onTap,
  });

  final String label;
  final bool hasSelection;
  final bool isOpen;
  final IconData? prefixIcon;
  final bool expanded;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashFactory: InkRipple.splashFactory,
        borderRadius: BorderRadius.circular(AppRadius.input),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppRadius.input),
            border: Border.all(
              color: isOpen
                  ? cs.primary.withValues(alpha: 0.6)
                  : cs.outlineVariant.withValues(alpha: 0.4),
              width: isOpen ? 1.4 : 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (prefixIcon != null) ...[
                Icon(prefixIcon, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
              ],
              if (expanded)
                Expanded(child: _buildLabel(cs, label, hasSelection))
              else
                _buildLabel(cs, label, hasSelection),
              const SizedBox(width: 8),
              AnimatedRotation(
                turns: isOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(ColorScheme cs, String label, bool hasSelection) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: hasSelection ? cs.onSurface : cs.onSurfaceVariant,
      ),
    );
  }
}

/// 下拉弹出菜单层。
class _AppDropdownOverlay<T> extends StatelessWidget {
  const _AppDropdownOverlay({
    required this.buttonRect,
    required this.overlaySize,
    required this.buttonWidth,
    required this.items,
    required this.selectedValue,
    required this.colorScheme,
    required this.fadeAnim,
    required this.slideAnim,
    required this.onItemSelected,
    required this.onDismiss,
  });

  final Rect buttonRect;
  final Size overlaySize;
  final double buttonWidth;
  final List<AppDropdownItem<T>> items;
  final T? selectedValue;
  final ColorScheme colorScheme;
  final Animation<double> fadeAnim;
  final Animation<Offset> slideAnim;
  final ValueChanged<T> onItemSelected;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final menuWidth = math.min(buttonWidth + 80, overlaySize.width - 24);
    final leftMargin = 12.0;
    final maxLeft = math.max(
      leftMargin,
      overlaySize.width - menuWidth - leftMargin,
    );
    final left = buttonRect.left.clamp(leftMargin, maxLeft).toDouble();
    final estimatedHeight = math.min(items.length * 44.0 + 8.0, 320.0);
    final aboveTop = buttonRect.top - 6.0 - estimatedHeight;
    final belowTop = buttonRect.bottom + 6.0;
    final top = belowTop + estimatedHeight > overlaySize.height - 12.0
        ? math.max(12.0, aboveTop)
        : belowTop;
    return Stack(
      children: [
        // 透明遮罩，点击关闭
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
          child: const SizedBox.expand(),
        ),
        Positioned(
          left: left,
          top: top,
          width: menuWidth,
          child: FadeTransition(
            opacity: fadeAnim,
            child: SlideTransition(
              position: slideAnim,
              child: Material(
                key: const ValueKey('app-dropdown-menu'),
                elevation: 6,
                borderRadius: BorderRadius.circular(AppRadius.input),
                shadowColor: cs.shadow,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.input),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final item = items[index];
                              final isSelected = item.value == selectedValue;
                              return _DropdownOption(
                                item: item,
                                isSelected: isSelected,
                                colorScheme: cs,
                                onTap: () => onItemSelected(item.value),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 下拉菜单中的单个选项。
class _DropdownOption<T> extends StatelessWidget {
  const _DropdownOption({
    required this.item,
    required this.isSelected,
    required this.colorScheme,
    required this.onTap,
  });

  final AppDropdownItem<T> item;
  final bool isSelected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return InkWell(
      onTap: onTap,
      splashFactory: InkRipple.splashFactory,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: isSelected
              ? cs.primaryContainer.withValues(alpha: 0.5)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (item.icon != null) ...[
              Icon(
                item.icon,
                size: 18,
                color: isSelected ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? cs.primary : cs.onSurface,
                ),
              ),
            ),
            if (isSelected)
              Icon(Icons.check_rounded, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}
