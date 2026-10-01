import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';

/// 定制下拉选择组件，替代原生 [DropdownButton]。
///
/// 使用 Overlay + AnimatedSwitcher 实现弹出菜单，避免原生样式的不一致。
/// 支持泛型 [T]，通过 [items] 提供选项，[value] 标记当前选中项。
///
/// 菜单展开期间拦截返回手势/系统返回键：返回只关闭菜单，不会 pop 外层页面或
/// 对话框（通过向所在 [ModalRoute] 注册 [PopEntry] 实现，关闭/销毁时注销）。
/// 展开前会先让当前输入框失焦；若软键盘正在显示，则等键盘收起（或超时）后再
/// 按稳定布局定位菜单，避免菜单被键盘遮挡或随布局抖动错位。
///
/// 全 App 下拉选择的**唯一实现**：筛选条直接使用；表单里传 [label] 得到
/// 「标题在上、撑满宽度」的表单字段形态。不要再使用 `DropdownButton` /
/// `DropdownButtonFormField` / `CupertinoPicker` 底部弹层自建下拉。
class AppDropdown<T> extends StatefulWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expanded = false,
    this.prefixIcon,
    this.hint,
    this.label,
    this.inline = false,
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

  /// 表单字段标题。非空时渲染在触发按钮上方并强制撑满宽度。
  final String? label;

  /// 列表行内形态：无底色无描边，只显示「当前值 + ⌃⌄」，放在
  /// `PlainListRow.trailing` 里使用（设置类表单：标题在左、值在右）。
  final bool inline;

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

/// 菜单展开期间向所在路由注册的 [PopEntry]：禁止路由被 pop，并把返回意图
/// 转为「关闭菜单」。
class _MenuPopEntry extends PopEntry<Object?> {
  _MenuPopEntry(this.onBack);

  final VoidCallback onBack;

  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier<bool>(false);

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) onBack();
  }
}

class _AppDropdownState<T> extends State<AppDropdown<T>>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 等待软键盘收起的最长时间，超时后按当前布局直接展开。
  static const _keyboardWaitTimeout = Duration(milliseconds: 450);

  late OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  ModalRoute<dynamic>? _popRoute;
  _MenuPopEntry? _popEntry;
  bool _waitingForKeyboard = false;
  Timer? _keyboardTimer;

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
    _cancelKeyboardWait();
    _unregisterPopEntry();
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

  double get _keyboardInset {
    final view = View.maybeOf(context);
    if (view == null) return 0;
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  void _openOverlay() {
    if (_waitingForKeyboard) return;
    // 先让输入框失焦（收起 IME），否则菜单可能被键盘遮挡。
    FocusManager.instance.primaryFocus?.unfocus();
    if (_keyboardInset > 0) {
      _waitingForKeyboard = true;
      WidgetsBinding.instance.addObserver(this);
      _keyboardTimer = Timer(_keyboardWaitTimeout, _finishKeyboardWait);
      return;
    }
    _showOverlay();
  }

  @override
  void didChangeMetrics() {
    if (_waitingForKeyboard && _keyboardInset <= 0) {
      // 等布局随键盘收起重排完成后再取按钮位置。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _finishKeyboardWait(),
      );
    }
  }

  void _finishKeyboardWait() {
    if (!_waitingForKeyboard) return;
    _cancelKeyboardWait();
    if (mounted && !_isOpen) _showOverlay();
  }

  void _cancelKeyboardWait() {
    if (!_waitingForKeyboard) return;
    _waitingForKeyboard = false;
    _keyboardTimer?.cancel();
    _keyboardTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  void _registerPopEntry() {
    _unregisterPopEntry();
    final route = ModalRoute.of(context);
    if (route == null) return;
    // 路由正在遍历 popEntries 派发回调，同步注销会触发并发修改，故延后到微任务。
    final entry = _MenuPopEntry(
      () => scheduleMicrotask(() {
        if (mounted) _closeOverlay();
      }),
    );
    route.registerPopEntry(entry);
    _popRoute = route;
    _popEntry = entry;
  }

  void _unregisterPopEntry() {
    final entry = _popEntry;
    if (entry == null) return;
    _popRoute?.unregisterPopEntry(entry);
    entry.canPopNotifier.dispose();
    _popRoute = null;
    _popEntry = null;
  }

  void _showOverlay() {
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
        bottomInset: _keyboardInset,
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
    _registerPopEntry();
    _animController.forward();
    setState(() => _isOpen = true);
  }

  void _closeOverlay({bool immediate = false}) {
    _cancelKeyboardWait();
    _unregisterPopEntry();
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
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;
    final fieldLabel = widget.label;

    if (widget.inline) {
      return _InlineDropdownButton(
        key: _buttonKey,
        label: label,
        hasSelection: hasSelection,
        colorScheme: cs,
        onTap: enabled ? _toggleOverlay : null,
      );
    }
    final button = _DropdownButton(
      key: _buttonKey,
      label: label,
      hasSelection: hasSelection,
      isOpen: _isOpen,
      prefixIcon: widget.prefixIcon,
      expanded: widget.expanded || fieldLabel != null,
      colorScheme: cs,
      onTap: enabled ? _toggleOverlay : null,
    );
    if (fieldLabel == null) return button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            fieldLabel,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        button,
      ],
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Material(
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

/// 列表行内的下拉触发器：值 + 上下箭头，无底色无描边。
class _InlineDropdownButton extends StatelessWidget {
  const _InlineDropdownButton({
    super.key,
    required this.label,
    required this.hasSelection,
    required this.colorScheme,
    required this.onTap,
  });

  final String label;
  final bool hasSelection;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final color = hasSelection ? cs.onSurfaceVariant : cs.outline;
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.input),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: color),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.unfold_more_rounded, size: 18, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 下拉弹出菜单层。
class _AppDropdownOverlay<T> extends StatelessWidget {
  const _AppDropdownOverlay({
    required this.buttonRect,
    required this.overlaySize,
    required this.bottomInset,
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

  /// 软键盘等遮挡底部的高度（逻辑像素），计算可用空间时扣除。
  final double bottomInset;
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
    final menuWidth = math.min(
      math.max(buttonWidth + 80, 168.0),
      overlaySize.width - 24,
    );
    final leftMargin = 12.0;
    final maxLeft = math.max(
      leftMargin,
      overlaySize.width - menuWidth - leftMargin,
    );
    final left = buttonRect.left.clamp(leftMargin, maxLeft).toDouble();
    final estimatedHeight = math.min(items.length * 44.0 + 8.0, 320.0);
    final aboveTop = buttonRect.top - 6.0 - estimatedHeight;
    final belowTop = buttonRect.bottom + 6.0;
    final availableBottom = overlaySize.height - bottomInset - 12.0;
    final top = belowTop + estimatedHeight > availableBottom
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
