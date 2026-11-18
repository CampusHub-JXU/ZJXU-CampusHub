import 'dart:async';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';

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
/// Dock），底部是真·可拖拽的工作台抽屉（[DraggableScrollableSheet]）。
/// 「实时预览」旁的放大按钮可把抽屉收至最小档、让预览铺满到屏底
/// （Dock 仍贴最小档位上沿保持可见），再次点按回到工作档位。
///
/// 壁纸画面不做任何全局磨砂/模糊遮罩：返回键、标题、「实时预览」标签、
/// 填充方式 chips、Dock 各自垫一枚只罩住控件自身的小磨砂 pill，
/// 壁纸全程完整可见。抽屉收起时露出把手与「壁纸」组，可向下拖到
/// 12%（只剩把手）或向上拖到 92%。
class HomePersonalizationPage extends StatefulWidget {
  const HomePersonalizationPage({super.key, this.homeSceneBuilder});

  /// 真实首页场景构建器（app 层注入 `HomeSurfaceScene`）。
  final WidgetBuilder? homeSceneBuilder;

  /// 工作台抽屉档位（相对屏幕高度）。
  static const _sheetMin = 0.12;
  static const _sheetInitial = 0.28;
  static const _sheetMax = 0.92;

  /// Dock 高（对齐 GlassNavBar 内部 SizedBox）。
  static const _dockHeight = 68.0;

  /// 抽屉收起位上沿与 Dock 底边的间距。
  static const _dockSheetGap = 12.0;

  @override
  State<HomePersonalizationPage> createState() =>
      _HomePersonalizationPageState();
}

class _HomePersonalizationPageState extends State<HomePersonalizationPage> {
  /// 预览滚动控制器：照旧透传给流体 Shader（预览自身不滚动，保留宿主语义，
  /// Shader 仍按「滚动/出视口暂停」接口工作）。
  final _previewScrollController = ScrollController();

  /// 工作台抽屉控制器：暴露给 widget 层（测试可用它直接跳档位，
  /// 不必模拟拖拽手势）。
  final _sheetController = DraggableScrollableController();

  /// 放大预览态：抽屉收至最小档、预览铺满到屏底（Dock 依旧可见）。
  bool _previewExpanded = false;

  void _togglePreviewExpanded() {
    setState(() => _previewExpanded = !_previewExpanded);
    if (_previewExpanded && _sheetController.isAttached) {
      // 收起抽屉时同步降到最小档，Dock 才不盖预览。
      unawaited(
        _sheetController.animateTo(
          HomePersonalizationPage._sheetMin,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  void dispose() {
    _previewScrollController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewHeight = constraints.maxHeight;
          // 抽屉占据屏底的高度；Dock 与快捷 chips 钉在它的上沿之上，
          // 保证收起/最小时 Dock 完整可见。放大预览时按最小档算，
          // 抽屉被收到 12%，预览实体继续延伸到屏底。
          final peekFraction = _previewExpanded
              ? HomePersonalizationPage._sheetMin
              : HomePersonalizationPage._sheetInitial;
          final sheetPeek = viewHeight * peekFraction;
          final dockBottom = sheetPeek + HomePersonalizationPage._dockSheetGap;
          final chipsBottom =
              dockBottom + HomePersonalizationPage._dockHeight + 10;
          return Stack(
            fit: StackFit.expand,
            children: [
              // 1) 整屏壁纸 / 流体 Shader 底，无全局磨砂遮罩。
              Positioned.fill(
                child: AppWallpaperBackdrop(
                  scrollController: _previewScrollController,
                ),
              ),
              // 2) 首页实体预览（不可交互），顶栏与 Dock 之间；
              //    放大预览时延伸进 Dock 与最小档抽屉后方（两者都半透明）。
              Positioned(
                left: 0,
                right: 0,
                top: topInset + kToolbarHeight + 44,
                bottom: _previewExpanded
                    ? 0
                    : dockBottom + HomePersonalizationPage._dockHeight,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: IgnorePointer(
                    child:
                        widget.homeSceneBuilder?.call(context) ??
                        const SizedBox.shrink(),
                  ),
                ),
              ),
              // 3) 「实时预览」标签 + 放大切换，钉在顶栏下方左侧。
              Positioned(
                left: 16,
                top: topInset + kToolbarHeight + 8,
                child: Row(
                  children: [
                    const _LiveTag(),
                    const SizedBox(width: 8),
                    _PreviewExpandButton(
                      expanded: _previewExpanded,
                      onPressed: _togglePreviewExpanded,
                    ),
                  ],
                ),
              ),
              // 4) 壁纸快捷操作：右下、Dock 上方（抽屉展开后自然被盖住；
              //    放大预览时同样隐藏，避免挡画面）。
              if (!_previewExpanded)
                Positioned(
                  right: 16,
                  bottom: chipsBottom,
                  child: const _PreviewFitChips(),
                ),
              // 5) 液态玻璃 Dock：抽屉收起/最小位完整可见。
              Positioned(
                left: 16,
                right: 16,
                bottom: dockBottom,
                child: const IgnorePointer(child: _PreviewDock()),
              ),
              // 6) 可拖拽工作台抽屉：把手 + 「壁纸/效果/首页内容/应用图标」。
              DraggableScrollableSheet(
                controller: _sheetController,
                initialChildSize: HomePersonalizationPage._sheetInitial,
                minChildSize: HomePersonalizationPage._sheetMin,
                maxChildSize: HomePersonalizationPage._sheetMax,
                snap: true,
                snapSizes: const [HomePersonalizationPage._sheetInitial],
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
                          color: cs.shadow.withValues(alpha: 0.22),
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
                          40 + MediaQuery.paddingOf(context).bottom,
                        ),
                        children: [
                          Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              margin: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: cs.outlineVariant,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const PersonalizationBackgroundSection(),
                          const SizedBox(height: kPlainListGroupGap),
                          const PersonalizationEffectsSection(),
                          const SizedBox(height: kPlainListGroupGap),
                          const PersonalizationHomeSection(),
                          const SizedBox(height: kPlainListGroupGap),
                          const PersonalizationIconSection(),
                        ],
                      ),
                    ),
                  );
                },
              ),
              // 7) 顶层返回键 + 标题：控件级磨砂 pill，不遮壁纸。
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(bottom: false, child: _TopBar()),
              ),
            ],
          );
        },
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
              child: _FrostedPill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
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

class _LiveTag extends StatelessWidget {
  const _LiveTag();

  @override
  Widget build(BuildContext context) {
    return _FrostedPill(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_outlined,
              size: 13,
              color: Colors.white.withValues(alpha: 0.9),
            ),
            const SizedBox(width: 5),
            Text(
              '实时预览',
              style: context.appText.meta.copyWith(
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「实时预览」旁的放大 / 还原切换：控件级磨砂 pill 内一枚小图标按钮。
/// 展开时抽屉收至最小档、预览实体铺满屏底，课表等文字可读到；
/// 再点一次回到工作档位（抽屉从 12% 拖回 28% 的工作位）。
class _PreviewExpandButton extends StatelessWidget {
  const _PreviewExpandButton({required this.expanded, required this.onPressed});

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _FrostedPill(
      child: IconButton(
        key: const Key('personalization_preview_expand'),
        icon: Icon(
          expanded
              ? Icons.close_fullscreen_rounded
              : Icons.open_in_full_rounded,
          size: 15,
        ),
        color: Colors.white.withValues(alpha: 0.92),
        tooltip: expanded ? '还原预览' : '放大预览',
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          minimumSize: const Size(30, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.all(5),
        ),
        onPressed: onPressed,
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
