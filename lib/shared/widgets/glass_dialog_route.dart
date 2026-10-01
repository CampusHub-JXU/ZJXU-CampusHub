import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import 'glass_container.dart';

/// overlay 档玻璃表面外壳。
///
/// 供玻璃化弹层（对话框/底部弹层/悬浮菜单）复用：内部通过
/// [GlassContainer]（[GlassTier.overlay]）提供 BackdropFilter 模糊 +
/// squircle tint 渐变 + 高光描边，裁剪位于 BackdropFilter 祖先位置
/// （ClipRRect 铁律由 GlassContainer 内部保证）。
///
/// [GlassStyleController] 总开关关闭或「模糊强度」拉到 0 时自动降级为
/// 实色表面，不创建 BackdropFilter，无需调用方分支处理。
class GlassOverlaySurface extends StatelessWidget {
  const GlassOverlaySurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;

  /// 缺省为 squircle 的 [AppRadius.floating]（28，与 M3 对话框圆角一致）；
  /// 底部弹层建议传入 `BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))`。
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      tier: GlassTier.overlay,
      borderRadius: borderRadius ?? BorderRadius.circular(AppRadius.floating),
      padding: padding,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

/// 玻璃化 [showDialog]。
///
/// 弹层表面使用 overlay 档真实模糊；玻璃关闭时降级为实色表面。常用方式是
/// 在 [builder] 内继续返回 `AlertDialog(backgroundColor: Colors.transparent,
/// elevation: 0, ...)`，由玻璃外壳负责材质与圆角，AlertDialog 只负责排版。
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,

  /// 语义与 [showDialog.barrierLabel] 一致（无障碍标签）。
  String? barrierLabel,
  bool useSafeArea = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  EdgeInsets insetPadding = const EdgeInsets.symmetric(
    horizontal: 40,
    vertical: 24,
  ),

  /// 玻璃表面圆角，缺省 [AppRadius.floating]。
  BorderRadius? borderRadius,

  /// 玻璃表面内边距；沿用 AlertDialog 内建排版时保持 EdgeInsets.zero。
  EdgeInsetsGeometry surfacePadding = EdgeInsets.zero,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: insetPadding,
        child: GlassOverlaySurface(
          borderRadius: borderRadius,
          padding: surfacePadding,
          // 外壳已按 [insetPadding] 让出屏幕边距；内层 AlertDialog 若再套默认
          // inset（40/24）会叠加两次，窄屏可用宽度被压到一半。
          child: Theme(
            data: theme.copyWith(
              dialogTheme: theme.dialogTheme.copyWith(
                insetPadding: EdgeInsets.zero,
              ),
            ),
            child: Builder(builder: builder),
          ),
        ),
      );
    },
  );
}

/// 玻璃化 [showModalBottomSheet]。
///
/// 弹层表面使用 overlay 档真实模糊 + 顶部 squircle 圆角；玻璃关闭时降级为
/// 实色表面。键盘避让与内容内边距由 [builder] 自行处理（与原生
/// [showModalBottomSheet] 的约定一致）。
Future<T?> showGlassModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useSafeArea = false,
  Color? barrierColor,
  String? barrierLabel,
  RouteSettings? routeSettings,
  BoxConstraints? constraints,
  bool showDragHandle = false,
  bool useRootNavigator = true,

  /// 玻璃表面圆角，缺省顶部 [AppRadius.sheet] 的 squircle 圆角。
  BorderRadius? borderRadius,

  /// 玻璃表面内边距。
  EdgeInsetsGeometry surfacePadding = EdgeInsets.zero,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useSafeArea: useSafeArea,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    routeSettings: routeSettings,
    constraints: constraints,
    showDragHandle: showDragHandle,
    useRootNavigator: useRootNavigator,
    builder: (sheetContext) => GlassOverlaySurface(
      borderRadius:
          borderRadius ??
          BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      padding: surfacePadding,
      child: SizedBox(width: double.infinity, child: builder(sheetContext)),
    ),
  );
}
