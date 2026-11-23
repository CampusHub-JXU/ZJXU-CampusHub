import 'package:material_ui/material_ui.dart';

import '../personalization_controller.dart';
import 'home_ambient_background.dart';
import 'home_background_layer.dart';

/// tab 页（主页 / 我的）共用的整屏背景：流体 Shader（不依赖壁纸，未设壁纸时
/// 按主题色配色）或用户壁纸 + 渐隐遮罩；既无壁纸又关了 Shader 时退回
/// [HomeAmbientBackground]。
///
/// 需在紧约束下使用（如 `Stack(fit: StackFit.expand)` 的首个子节点）。
///
/// 背景高度锁定为整屏高度：软键盘弹出时 Scaffold 会压缩 body，若背景跟着
/// 变矮，Shader 画布与渐隐遮罩会整体被「顶起」。这里让背景按屏幕高度顶部
/// 对齐溢出，被键盘遮住的部分由父级 Stack 裁掉。
class AppWallpaperBackdrop extends StatelessWidget {
  const AppWallpaperBackdrop({super.key, this.scrollController});

  /// 宿主页面滚动控制器：透传给流体 Shader，滚动 / 出视口时暂停出帧。
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? (constraints.maxHeight > screenHeight
                  ? constraints.maxHeight
                  : screenHeight)
            : screenHeight;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: height,
            maxHeight: height,
            child: _buildBackdrop(context),
          ),
        );
      },
    );
  }

  Widget _buildBackdrop(BuildContext context) {
    final personalization = PersonalizationController.instance;
    return ValueListenableBuilder<String?>(
      valueListenable: personalization.backgroundImagePath,
      builder: (context, bgImagePath, _) => ValueListenableBuilder<bool>(
        valueListenable: personalization.shaderEnabled,
        builder: (context, shaderEnabled, _) {
          if (bgImagePath == null && !shaderEnabled) {
            return const HomeAmbientBackground();
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              HomeBackgroundLayer(
                path: bgImagePath,
                scrollController: scrollController,
              ),
              ..._overlays(context, shaderEnabled: shaderEnabled),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _overlays(BuildContext context, {required bool shaderEnabled}) {
    final theme = Theme.of(context);
    final scaffold = theme.scaffoldBackgroundColor;
    final surface = theme.colorScheme.surface;
    final topInset = MediaQuery.paddingOf(context).top;
    if (!shaderEnabled) {
      // 禁用 Shader 保持原布局：纯壁纸形态在状态栏区域垫一层表面色保障图标可读
      return [
        if (topInset > 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topInset,
            child: DecoratedBox(
              decoration: BoxDecoration(color: surface.withValues(alpha: 0.94)),
            ),
          ),
      ];
    }
    return [
      // Hero 舞台氛围渐隐遮罩（Hero Fade Scrim）：
      // 顶部保持 0 遮罩，让克制的丝绸微光无断层延伸至状态栏；
      // 向下按 9 点五次 smootherstep 缓动曲线（起止斜率均为 0）无缝融进
      // scaffoldBackgroundColor，彻底消除折线阶梯感与顶部发白横带。
      Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [
                  0.0,
                  0.08,
                  0.16,
                  0.24,
                  0.33,
                  0.42,
                  0.51,
                  0.60,
                  1.0,
                ],
                colors: [
                  scaffold.withValues(alpha: 0.0),
                  scaffold.withValues(alpha: 0.01),
                  scaffold.withValues(alpha: 0.07),
                  scaffold.withValues(alpha: 0.24),
                  scaffold.withValues(alpha: 0.52),
                  scaffold.withValues(alpha: 0.79),
                  scaffold.withValues(alpha: 0.95),
                  scaffold,
                  scaffold,
                ],
              ),
            ),
          ),
        ),
      ),
    ];
  }
}
