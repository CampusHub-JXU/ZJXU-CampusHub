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
                // 内层 AlertDialog 自带一个 Dialog，其 `Align` 会撑满父级最大
                // 高度。为了让内容给人的是「无界高度」（见下），这里必须先把
                // 内层宽度锁成「撑满可用宽度」的紧约束：否则 AlertDialog 的
                // `IntrinsicWidth` 会以无界高度求内在宽度，一路深入内容的懒加载
                // 视图（如 `ListView(shrinkWrap: true)`）并抛异常。玻璃的可见宽度
                // 本就由外层 `Align` 撑满，锁紧后视觉不变。
                constraints: const BoxConstraints.tightFor(
                  width: double.maxFinite,
                ),
              ),
            ),
            // 关键：给内容无界高度，内层 Dialog 的 `Align` 便不再撑满，转而在
            // 竖直方向收缩到内容高度——玻璃表面随之 shrink-wrap 并居中（内层
            // Dialog 不再有整屏空白）。内容超过可用高度时视口封顶并可滚动，
            // 操作按钮仍可触达。
            child: SingleChildScrollView(
              primary: false,
              child: Builder(builder: builder),
            ),
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
    // 拖拽把手自己画在玻璃表面里：Material 的把手画在透明 BottomSheet 上、
    // 玻璃表面之外，会悬在遮罩上。拖拽手势仍由 BottomSheet（enableDrag）处理。
    showDragHandle: false,
    useRootNavigator: useRootNavigator,
    builder: (sheetContext) => GlassOverlaySurface(
      borderRadius:
          borderRadius ??
          BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      padding: surfacePadding,
      child: SizedBox(
        width: double.infinity,
        child: showDragHandle
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _GlassSheetDragHandle(),
                  Flexible(child: builder(sheetContext)),
                ],
              )
            : builder(sheetContext),
      ),
    ),
  );
}

/// 与 M3 `DragHandle` 同尺寸（32×4，上下留白合计 22）的把手。
class _GlassSheetDragHandle extends StatelessWidget {
  const _GlassSheetDragHandle();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 10),
      child: Container(
        width: 32,
        height: 4,
        decoration: ShapeDecoration(
          color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}
