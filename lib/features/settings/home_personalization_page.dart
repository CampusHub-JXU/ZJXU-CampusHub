import 'dart:async';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/personalization_controller.dart';
import '../../core/theme/widgets/app_wallpaper_backdrop.dart';
import '../../shared/widgets/glass_nav_bar.dart';
import '../../shared/widgets/plain_list.dart';
import 'widgets/personalization_background_section.dart';
import 'widgets/personalization_effects_section.dart';
import 'widgets/personalization_home_section.dart';
import 'widgets/personalization_icon_section.dart';

/// 「首页个性化」编辑台：整屏 1:1 实时预览（壁纸 / 首页内容 / 液态玻璃
/// Dock），默认收起设置抽屉、让预览垂直撑满全屏；底部中央保留悬浮
/// pill 把手，点按或上滑后滑入覆盖式工作台抽屉（[DraggableScrollableSheet]），
/// 下滑或点按轻遮罩即可收起。
class HomePersonalizationPage extends StatefulWidget {
  const HomePersonalizationPage({super.key, this.homeSceneBuilder});

  /// 真实首页场景构建器（app 层注入 `HomeSurfaceScene`）。
  final WidgetBuilder? homeSceneBuilder;

  /// 工作台抽屉档位（相对屏幕高度）：默认打开到 72%，可上拉至 88%，
  /// 下拉低于阈值后回到 0% 自动收起。
  static const _sheetInitial = 0.72;
  static const _sheetMax = 0.88;
  static const _sheetDismissExtent = 0.02;

  /// 贴底 Dock 高（对齐 GlassNavBar._barHeight）。
  static const _dockHeight = 58.0;

  @override
  State<HomePersonalizationPage> createState() =>
      _HomePersonalizationPageState();
}

class _HomePersonalizationPageState extends State<HomePersonalizationPage>
    with SingleTickerProviderStateMixin {
  /// 预览滚动控制器：照旧透传给流体 Shader（预览自身不滚动，保留宿主语义，
  /// Shader 仍按「滚动/出视口暂停」接口工作）。
  final _previewScrollController = ScrollController();

  /// 工作台抽屉控制器：暴露给 widget 层（测试可用它直接跳档位）。
  final _sheetController = DraggableScrollableController();

  /// 追踪抽屉当前高度占比，让背景轻遮罩随下拉手势同步淡出。
  final _sheetExtent = ValueNotifier<double>(
    HomePersonalizationPage._sheetInitial,
  );

  late final AnimationController _drawerController;
  late final CurvedAnimation _drawerAnimation;

  bool _drawerOpen = false;
  bool _closingByAnimation = false;
  double _dragUpAccumulated = 0;

  @override
  void initState() {
    super.initState();
    _drawerController = AnimationController(
      vsync: this,
      duration: AppMotion.page,
      reverseDuration: AppMotion.page,
    );
    _drawerAnimation = CurvedAnimation(
      parent: _drawerController,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.standardReverse,
    );
  }

  void _openDrawer() {
    if (_drawerOpen && !_closingByAnimation) return;
    _closingByAnimation = false;
    _sheetExtent.value = HomePersonalizationPage._sheetInitial;
    setState(() => _drawerOpen = true);
    unawaited(_drawerController.forward());
  }

  Future<void> _closeDrawer() async {
    if (!_drawerOpen || _closingByAnimation) return;
    _closingByAnimation = true;
    await _drawerController.reverse();
    if (!mounted || !_closingByAnimation) return;
    setState(() {
      _drawerOpen = false;
      _closingByAnimation = false;
      _sheetExtent.value = HomePersonalizationPage._sheetInitial;
    });
  }

  void _onHandleDragStart(DragStartDetails _) {
    _dragUpAccumulated = 0;
  }

  void _onHandleDragUpdate(DragUpdateDetails details, double viewHeight) {
    _dragUpAccumulated -= details.delta.dy;
    if (_dragUpAccumulated <= 4) return;
    if (!_drawerOpen) {
      _closingByAnimation = false;
      _sheetExtent.value = HomePersonalizationPage._sheetInitial;
      setState(() => _drawerOpen = true);
    }
    final progress = (_dragUpAccumulated / (viewHeight * 0.45)).clamp(0.0, 1.0);
    _drawerController.value = progress;
  }

  void _onHandleDragEnd(DragEndDetails details) {
    if (!_drawerOpen) return;
    final upwardVelocity = -(details.primaryVelocity ?? 0);
    if (upwardVelocity > 200 || _drawerController.value > 0.18) {
      unawaited(_drawerController.forward());
    } else {
      unawaited(_closeDrawer());
    }
  }

  bool _onSheetNotification(DraggableScrollableNotification notification) {
    _sheetExtent.value = notification.extent;
    if (notification.extent <= HomePersonalizationPage._sheetDismissExtent &&
        _drawerOpen &&
        !_closingByAnimation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_drawerOpen || _closingByAnimation) return;
        if (_sheetExtent.value <= HomePersonalizationPage._sheetDismissExtent) {
          setState(() {
            _drawerOpen = false;
            _drawerController.value = 0;
            _sheetExtent.value = HomePersonalizationPage._sheetInitial;
          });
        }
      });
    }
    return false;
  }

  @override
  void dispose() {
    _previewScrollController.dispose();
    _sheetController.dispose();
    _sheetExtent.dispose();
    _drawerAnimation.dispose();
    _drawerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    final topInset = mediaPadding.top;
    final dockTotalHeight =
        HomePersonalizationPage._dockHeight + mediaPadding.bottom;
    return PopScope(
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _drawerOpen) {
          unawaited(_closeDrawer());
        }
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final viewHeight = constraints.maxHeight;
            return Stack(
              fit: StackFit.expand,
              children: [
                // 1) 整屏壁纸 / 流体 Shader 底，无全局磨砂遮罩。
                Positioned.fill(
                  child: AppWallpaperBackdrop(
                    scrollController: _previewScrollController,
                  ),
                ),
                // 2) 首页实体预览（不可交互），顶栏下方垂直撑满至屏底（贴近真实 extendBody）。
                Positioned(
                  left: 0,
                  right: 0,
                  top: topInset + kToolbarHeight,
                  bottom: 0,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: IgnorePointer(
                      child:
                          widget.homeSceneBuilder?.call(context) ??
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
                // 3) 贴底液态玻璃 Dock（与真实首页一致）。
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(child: _PreviewDock()),
                ),
                // 4) 壁纸快捷操作：右下、处于把手上方，避免在窄屏横向碰撞。
                Positioned(
                  right: 16,
                  bottom: dockTotalHeight + 52,
                  child: const _PreviewFitChips(),
                ),
                // 5) 底部中央悬浮抽屉入口 pill：点按或上滑滑出工作台抽屉。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: dockTotalHeight + 6,
                  child: Center(
                    child: _DrawerHandlePill(
                      onTap: _openDrawer,
                      onVerticalDragStart: _onHandleDragStart,
                      onVerticalDragUpdate: (d) =>
                          _onHandleDragUpdate(d, viewHeight),
                      onVerticalDragEnd: _onHandleDragEnd,
                    ),
                  ),
                ),
                // 6) 顶层返回键 + 标题：控件级磨砂 pill，不遮壁纸。
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(bottom: false, child: _TopBar()),
                ),
                // 7) 滑入覆盖式工作台抽屉（默认收起，不占常驻高度）。
                if (_drawerOpen)
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _drawerAnimation,
                      builder: (context, child) {
                        return ValueListenableBuilder<double>(
                          valueListenable: _sheetExtent,
                          builder: (context, extent, _) {
                            final scrimFactor =
                                _drawerAnimation.value *
                                (extent / HomePersonalizationPage._sheetInitial)
                                    .clamp(0.0, 1.0);
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                GestureDetector(
                                  key: const Key(
                                    'personalization_drawer_scrim',
                                  ),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _closeDrawer,
                                  child: ColoredBox(
                                    color: Colors.black.withValues(
                                      alpha: 0.28 * scrimFactor,
                                    ),
                                  ),
                                ),
                                FractionalTranslation(
                                  translation: Offset(
                                    0,
                                    1 - _drawerAnimation.value,
                                  ),
                                  child: child,
                                ),
                              ],
                            );
                          },
                        );
                      },
                      child:
                          NotificationListener<DraggableScrollableNotification>(
                            onNotification: _onSheetNotification,
                            child: DraggableScrollableSheet(
                              controller: _sheetController,
                              initialChildSize:
                                  HomePersonalizationPage._sheetInitial,
                              minChildSize: 0.0,
                              maxChildSize: HomePersonalizationPage._sheetMax,
                              snap: true,
                              snapSizes: const [
                                HomePersonalizationPage._sheetInitial,
                                HomePersonalizationPage._sheetMax,
                              ],
                              builder: (context, sheetController) {
                                final theme = Theme.of(context);
                                final cs = theme.colorScheme;
                                return Container(
                                  decoration: BoxDecoration(
                                    color: theme.scaffoldBackgroundColor,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(28),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: cs.shadow.withValues(
                                          alpha: 0.22,
                                        ),
                                        blurRadius: 24,
                                        offset: const Offset(0, -6),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(28),
                                    ),
                                    child: ListView(
                                      key: const Key('personalization_scroll'),
                                      controller: sheetController,
                                      padding: EdgeInsets.fromLTRB(
                                        kPlainListGutter,
                                        0,
                                        kPlainListGutter,
                                        40 + mediaPadding.bottom,
                                      ),
                                      children: [
                                        Center(
                                          child: Container(
                                            width: 36,
                                            height: 4,
                                            margin: const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                            decoration: BoxDecoration(
                                              color: cs.outlineVariant,
                                              borderRadius:
                                                  BorderRadius.circular(2),
                                            ),
                                          ),
                                        ),
                                        const PersonalizationBackgroundSection(),
                                        const SizedBox(
                                          height: kPlainListGroupGap,
                                        ),
                                        const PersonalizationEffectsSection(),
                                        const SizedBox(
                                          height: kPlainListGroupGap,
                                        ),
                                        const PersonalizationHomeSection(),
                                        const SizedBox(
                                          height: kPlainListGroupGap,
                                        ),
                                        const PersonalizationIconSection(),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 顶栏：返回键与标题各自垫一枚小磨砂 pill（仅罩住控件 bounds），
/// 亮壁纸上仍可读，又不形成横贯屏幕的磨砂带。
class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: [
          _FrostedPill(
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              color: Colors.white,
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                '首页个性化',
                style: context.appText.title.copyWith(
                  color: Colors.white,
                  shadows: const [
                    Shadow(blurRadius: 8, color: Color(0x55000000)),
                  ],
                ),
              ),
            ),
          ),
          // 与返回键等宽占位，标题保持视觉居中。
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// 控件级磨砂底座：BackdropFilter 只垫在控件自身矩形内。
class _FrostedPill extends StatelessWidget {
  const _FrostedPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: ColoredBox(color: const Color(0x660B0F16), child: child),
      ),
    );
  }
}

/// 预览里的液态玻璃 Dock 实体（不可点按）。
class _PreviewDock extends StatelessWidget {
  const _PreviewDock();

  @override
  Widget build(BuildContext context) {
    return const GlassNavBar(
      currentIndex: 0,
      onDestinationSelected: _noopNav,
      destinations: [
        GlassNavBarDestination(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          label: '主页',
        ),
        GlassNavBarDestination(
          icon: Icons.widgets_outlined,
          selectedIcon: Icons.widgets,
          label: '功能',
        ),
        GlassNavBarDestination(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: '我的',
        ),
      ],
    );
  }

  static void _noopNav(int _) {}
}

/// 底部中央悬浮把手：点按或上滑滑出个性化工作台抽屉。
class _DrawerHandlePill extends StatelessWidget {
  const _DrawerHandlePill({
    required this.onTap,
    required this.onVerticalDragStart,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
  });

  final VoidCallback onTap;
  final GestureDragStartCallback onVerticalDragStart;
  final GestureDragUpdateCallback onVerticalDragUpdate;
  final GestureDragEndCallback onVerticalDragEnd;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '打开个性化设置抽屉',
      child: GestureDetector(
        key: const Key('personalization_drawer_handle'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onVerticalDragStart: onVerticalDragStart,
        onVerticalDragUpdate: onVerticalDragUpdate,
        onVerticalDragEnd: onVerticalDragEnd,
        child: Padding(
          // 扩大触控热区，视觉保持紧凑悬浮 pill。
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: _FrostedPill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 16,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '编辑样式',
                    style: context.appText.meta.copyWith(
                      color: Colors.white.withValues(alpha: 0.94),
                      fontWeight: FontWeight.w600,
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

/// 叠在预览上的壁纸快捷操作：有壁纸时提供填充方式三段与「位置/缩放」。
class _PreviewFitChips extends StatelessWidget {
  const _PreviewFitChips();

  @override
  Widget build(BuildContext context) {
    final controller = PersonalizationController.instance;
    return ValueListenableBuilder<String?>(
      valueListenable: controller.backgroundImagePath,
      builder: (context, bgPath, _) {
        if (bgPath == null) {
          return const _ChipButton(
            icon: Icons.wallpaper_outlined,
            label: '更换壁纸',
            action: _ChipAction.pick,
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ValueListenableBuilder<HomeBackgroundFit>(
              valueListenable: controller.backgroundFit,
              builder: (context, fit, _) {
                final exposed = kWallpaperFitSegments.any((s) => s.$1 == fit);
                return _FitChipGroup(
                  selected: exposed ? fit : null,
                  onSelect: controller.setBackgroundFit,
                );
              },
            ),
            const SizedBox(height: 8),
            _ChipButton(
              icon: Icons.crop_free,
              label: '位置 / 缩放',
              action: _ChipAction.edit,
              wallpaperPath: bgPath,
            ),
          ],
        );
      },
    );
  }
}

enum _ChipAction { pick, edit }

class _ChipButton extends StatelessWidget {
  const _ChipButton({
    required this.icon,
    required this.label,
    required this.action,
    this.wallpaperPath,
  });

  final IconData icon;
  final String label;
  final _ChipAction action;
  final String? wallpaperPath;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Material(
          color: const Color(0x660B0F16),
          child: InkWell(
            onTap: () {
              switch (action) {
                case _ChipAction.pick:
                  pickHomeWallpaperImage(context);
                case _ChipAction.edit:
                  final path = wallpaperPath;
                  if (path != null) {
                    editHomeWallpaperTransform(context, path);
                  }
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: Colors.white),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: context.appText.meta.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
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

class _FitChipGroup extends StatelessWidget {
  const _FitChipGroup({required this.selected, required this.onSelect});

  final HomeBackgroundFit? selected;
  final ValueChanged<HomeBackgroundFit> onSelect;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          color: const Color(0x660B0F16),
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (value, label) in kWallpaperFitSegments)
                GestureDetector(
                  onTap: () => onSelect(value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: selected == value
                          ? Colors.white.withValues(alpha: 0.22)
                          : Colors.transparent,
                    ),
                    child: Text(
                      label,
                      style: context.appText.meta.copyWith(
                        color: selected == value
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.65),
                        fontWeight: selected == value
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
