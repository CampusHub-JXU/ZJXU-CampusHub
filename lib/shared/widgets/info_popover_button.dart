import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';

/// 行尾的 ⓘ 按钮：点按弹出说明 popover，点外部 / 再点 ⓘ 关闭。
///
/// 用来把设置行的说明性副标题收起来（`docs/desktop-widget-v2.md` §6）：行本身
/// 只留标题 + 短状态，解释放进这里。用点按弹出而不是长按 `Tooltip`——手机上长按
/// 不可发现。按钮命中区 48dp，与所在行的点按区域互不重叠。
class InfoPopoverButton extends StatefulWidget {
  const InfoPopoverButton({
    super.key,
    required this.subject,
    required this.message,
  });

  /// 说明的对象（通常就是行标题），用于读屏标签「关于 + subject」。
  final String subject;

  /// 说明正文，可多行。
  final String message;

  @override
  State<InfoPopoverButton> createState() => _InfoPopoverButtonState();
}

class _InfoPopoverButtonState extends State<InfoPopoverButton>
    with SingleTickerProviderStateMixin {
  static const double _maxWidth = 280;
  static const double _gap = 4;

  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: AppMotion.quick,
  );

  /// 按钮位于屏幕下半部时向上弹出，避免被底部截断。
  bool _above = false;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _toggle() => _portal.isShowing ? _hide() : _show();

  void _show() {
    final box = context.findRenderObject() as RenderBox?;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (box != null && box.hasSize) {
      final center = box.localToGlobal(box.size.center(Offset.zero));
      _above = center.dy > screenHeight * 0.6;
    }
    setState(_portal.show);
    if (AppMotion.reduced(context)) {
      _anim.value = 1;
    } else {
      _anim.forward(from: 0);
    }
  }

  Future<void> _hide() async {
    if (!_portal.isShowing) return;
    if (AppMotion.reduced(context)) {
      _anim.value = 0;
    } else {
      await _anim.reverse();
    }
    if (mounted && _portal.isShowing) setState(_portal.hide);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TapRegion(
      groupId: this,
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _buildPopover,
          child: Semantics(
            container: true,
            label: '关于${widget.subject}',
            button: true,
            onTap: _toggle,
            excludeSemantics: true,
            child: IconButton(
              onPressed: _toggle,
              icon: Icon(Icons.info_outline, size: 20, color: cs.outline),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPopover(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final curved = CurvedAnimation(
      parent: _anim,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.standardReverse,
    );
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: _above ? Alignment.topRight : Alignment.bottomRight,
      followerAnchor: _above ? Alignment.bottomRight : Alignment.topRight,
      offset: Offset(0, _above ? -_gap : _gap),
      child: Align(
        alignment: _above ? Alignment.bottomRight : Alignment.topRight,
        child: TapRegion(
          groupId: this,
          onTapOutside: (_) => _hide(),
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
              alignment: _above ? Alignment.bottomRight : Alignment.topRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                // 实底而非磨砂：popover 盖在同色列表上，半透明会让下面的行文字
                // 透出来，读不清（模拟器实测）。
                child: Material(
                  color: isDark
                      ? cs.surfaceContainerHigh
                      : cs.surfaceContainerLowest,
                  elevation: 6,
                  shadowColor: Colors.black.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Semantics(
                      container: true,
                      liveRegion: true,
                      child: Text(
                        widget.message,
                        style: text.secondary.copyWith(color: cs.onSurface),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
