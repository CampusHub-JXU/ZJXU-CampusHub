import 'package:flutter/material.dart';

import '../personalization_controller.dart';
import 'home_ambient_background.dart';
import 'home_background_layer.dart';

/// tab 页（主页 / 我的）共用的整屏背景：流体 Shader（不依赖壁纸，未设壁纸时
/// 按主题色配色）或用户壁纸 + 渐隐遮罩；既无壁纸又关了 Shader 时退回
/// [HomeAmbientBackground]。
///
/// 需在紧约束下使用（如 `Stack(fit: StackFit.expand)` 的首个子节点）。
class AppWallpaperBackdrop extends StatelessWidget {
  const AppWallpaperBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
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
              HomeBackgroundLayer(path: bgImagePath),
              ..._overlays(context, shaderEnabled: shaderEnabled),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _overlays(BuildContext context, {required bool shaderEnabled}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
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
      // 顶部保留 Shader / 背景微光氛围并附带柔和 tint 保护，
      // 向下平滑过渡到纯净主题表面（scaffoldBackgroundColor），
      // 保证正文直接坐在稳定主题底色上。
      Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.18, 0.36, 0.52, 1.0],
                colors: [
                  scaffold.withValues(alpha: isDark ? 0.45 : 0.32),
                  scaffold.withValues(alpha: isDark ? 0.52 : 0.40),
                  scaffold.withValues(alpha: isDark ? 0.82 : 0.76),
                  scaffold,
                  scaffold,
                ],
              ),
            ),
          ),
        ),
      ),
      // 状态栏顶部柔和微羽化，保障极端高光壁纸下系统状态图标清晰可读
      if (topInset > 0)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topInset + 8,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    surface.withValues(alpha: isDark ? 0.38 : 0.28),
                    surface.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
  }
}
