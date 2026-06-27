import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/app_theme_controller.dart';
import '../../core/theme/app_design_tokens.dart';
import '../home/home_controller.dart';
import '../home/widgets/home_background_layer.dart';
import 'widgets/glass_preset_control.dart';
import 'widgets/shader_tuning_controls.dart';

class PersonalizationPage extends StatefulWidget {
  const PersonalizationPage({super.key});

  @override
  State<PersonalizationPage> createState() => _PersonalizationPageState();
}

class _PersonalizationPageState extends State<PersonalizationPage> {
  bool _previewDragging = false;
  double _gestureStartScale = 1.0;
  Alignment _gestureStartAlignment = Alignment.center;
  Offset _gestureStartFocalPoint = Offset.zero;

  Future<void> _pickHomeBackgroundImage(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (picked == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final destDir = Directory('${appDir.path}/home_bg');
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      } else {
        await for (final file in destDir.list()) {
          if (file is File) {
            unawaited(file.delete().catchError((_) => file));
          }
        }
      }

      final dotIdx = picked.path.lastIndexOf('.');
      final ext = dotIdx == -1 ? '.jpg' : picked.path.substring(dotIdx);
      final destPath =
          '${destDir.path}/bg_${DateTime.now().millisecondsSinceEpoch}$ext';

      await File(picked.path).copy(destPath);
      await HomeController.instance.setBackgroundImagePath(destPath);
      await AppThemeController.instance.refreshMonetSeed();

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已设置首页背景')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('选择图片失败，请稍后重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('首页个性化')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _buildPreviewSection(context, maxHeight: 320),
          ),
          Expanded(
            child: ListView(
              physics: _previewDragging
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                _buildBackgroundSection(context, textTheme),
                const SizedBox(height: 16),
                _buildFilterSection(context, textTheme),
                const SizedBox(height: 16),
                _buildGlassSection(context, textTheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Preview ---

  Widget _buildPreviewSection(BuildContext context, {double maxHeight = 520}) {
    return ValueListenableBuilder<String?>(
      valueListenable: HomeController.instance.backgroundImagePath,
      builder: (context, bgPath, _) {
        if (bgPath == null) {
          return Card(
            clipBehavior: Clip.antiAlias,
            child: Container(
              height: 120,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.wallpaper_outlined,
                    size: 36,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '暂未设置背景图片',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ValueListenableBuilder<Alignment>(
          valueListenable: HomeController.instance.backgroundAlignment,
          builder: (context, alignment, _) {
            return ValueListenableBuilder<double>(
              valueListenable: HomeController.instance.backgroundScale,
              builder: (context, scale, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final frameSize = _homePreviewFrameSize(
                      context,
                      constraints.maxWidth,
                      maxHeight: maxHeight,
                    );
                    final frameWidth = frameSize.width;
                    final frameHeight = frameSize.height;
                    return Center(
                      child: SizedBox(
                        width: frameWidth,
                        height: frameHeight,
                        child: ClipRRect(
                          borderRadius: AppRadius.tileBorder,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onScaleStart: (details) {
                                _gestureStartScale = scale;
                                _gestureStartAlignment = alignment;
                                _gestureStartFocalPoint = details.focalPoint;
                                setState(() => _previewDragging = true);
                              },
                              onScaleUpdate: (details) {
                                _updatePreviewTransform(
                                  focalPoint: details.focalPoint,
                                  frameSize: frameSize,
                                  scale: details.scale,
                                );
                              },
                              onScaleEnd: (_) {
                                setState(() => _previewDragging = false);
                                HomeController.instance.setBackgroundAlignment(
                                  HomeController
                                      .instance
                                      .backgroundAlignment
                                      .value,
                                );
                                HomeController.instance.setBackgroundScale(
                                  HomeController.instance.backgroundScale.value,
                                );
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  HomeBackgroundLayer(
                                    path: bgPath,
                                    errorBuilder: (context) {
                                      return Container(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHigh,
                                        child: const Center(
                                          child: Icon(
                                            Icons.broken_image_outlined,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  _buildHomeWidgetPreviewOverlay(context),
                                  Positioned(
                                    top: 10,
                                    right: 10,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.42,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppRadius.chip,
                                        ),
                                      ),
                                      child: const Text(
                                        '首页可见区域 · 拖动/双指缩放',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Size _homePreviewFrameSize(
    BuildContext context,
    double maxWidth, {
    double maxHeight = 520,
  }) {
    final media = MediaQuery.of(context);
    const bottomNavigationHeight = 80.0;
    final visibleHeight = math.max(
      1.0,
      media.size.height -
          media.padding.top -
          media.padding.bottom -
          bottomNavigationHeight,
    );
    final aspect = media.size.width / visibleHeight;
    final frameWidth = maxWidth;
    final frameHeight = math.min(maxHeight, frameWidth / aspect);
    return Size(frameHeight * aspect, frameHeight);
  }

  Widget _buildHomeWidgetPreviewOverlay(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: HomeController.instance.headerGlassEnabled,
      builder: (context, headerGlassEnabled, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: HomeController.instance.frostedGlassEnabled,
          builder: (context, cardGlassEnabled, _) {
            return ValueListenableBuilder<double>(
              valueListenable: HomeController.instance.glassBlur,
              builder: (context, glassBlur, _) {
                return ValueListenableBuilder<double>(
                  valueListenable: HomeController.instance.glassOpacity,
                  builder: (context, glassOpacity, _) {
                    return _buildHomeWidgetPreviewBoxes(
                      context,
                      headerGlassEnabled: headerGlassEnabled,
                      cardGlassEnabled: cardGlassEnabled,
                      glassBlur: glassBlur,
                      glassOpacity: glassOpacity,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildHomeWidgetPreviewBoxes(
    BuildContext context, {
    required bool headerGlassEnabled,
    required bool cardGlassEnabled,
    required double glassBlur,
    required double glassOpacity,
  }) {
    Widget box({
      required double left,
      required double top,
      required double width,
      required double height,
      required bool glassEnabled,
      double radius = 10,
    }) {
      final borderRadius = BorderRadius.circular(radius);
      final surfaceAlpha = glassEnabled ? glassOpacity : 0.16;
      final borderAlpha = glassEnabled ? 0.42 : 0.72;
      final content = DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: surfaceAlpha),
          borderRadius: borderRadius,
          border: Border.all(
            color: Colors.white.withValues(alpha: borderAlpha),
            width: 1.2,
          ),
        ),
      );
      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: IgnorePointer(
          child: ClipRRect(
            borderRadius: borderRadius,
            child: glassEnabled
                ? BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: glassBlur,
                      sigmaY: glassBlur,
                    ),
                    child: content,
                  )
                : content,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final pad = w * 0.055;
        return Stack(
          children: [
            box(
              left: pad,
              top: h * 0.09,
              width: w - pad * 2,
              height: h * 0.22,
              glassEnabled: headerGlassEnabled,
              radius: 16,
            ),
            box(
              left: pad,
              top: h * 0.36,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.16,
              glassEnabled: cardGlassEnabled,
            ),
            box(
              left: pad + (w - pad * 2 + 8) / 2,
              top: h * 0.36,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.13,
              glassEnabled: cardGlassEnabled,
            ),
            box(
              left: pad,
              top: h * 0.54,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.10,
              glassEnabled: cardGlassEnabled,
            ),
            box(
              left: pad + (w - pad * 2 + 8) / 2,
              top: h * 0.51,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.10,
              glassEnabled: cardGlassEnabled,
            ),
          ],
        );
      },
    );
  }

  void _updatePreviewTransform({
    required Offset focalPoint,
    required Size frameSize,
    required double scale,
  }) {
    final delta = focalPoint - _gestureStartFocalPoint;
    HomeController.instance.backgroundAlignment.value = Alignment(
      (_gestureStartAlignment.x + delta.dx / frameSize.width * 2).clamp(
        -2.0,
        2.0,
      ),
      (_gestureStartAlignment.y + delta.dy / frameSize.height * 2).clamp(
        -2.0,
        2.0,
      ),
    );
    HomeController.instance.backgroundScale.value = (_gestureStartScale * scale)
        .clamp(0.5, 3.0);
  }

  // --- Background ---

  Widget _buildBackgroundSection(BuildContext context, TextTheme textTheme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Text('背景图片', style: textTheme.titleSmall),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: HomeController.instance.backgroundImagePath,
            builder: (context, bgPath, _) {
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.wallpaper_outlined),
                    title: const Text('选择背景图片'),
                    subtitle: Text(bgPath != null ? '已设置自定义背景' : '未设置，使用默认背景'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickHomeBackgroundImage(context),
                  ),
                  if (bgPath != null) ...[
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('移除背景图片'),
                      onTap: () async {
                        await HomeController.instance.clearBackgroundImage();
                        await HomeController.instance.setShaderEnabled(false);
                        await AppThemeController.instance.refreshMonetSeed();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已移除首页背景')),
                          );
                        }
                      },
                    ),
                    _buildBackgroundOpacitySlider(),
                    _buildBackgroundFitPicker(context),
                    _buildBackgroundPositionControls(context),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundOpacitySlider() {
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.backgroundOpacity,
      builder: (context, opacity, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '透明度  ${(opacity * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Slider.adaptive(
              value: opacity,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: HomeController.instance.setBackgroundOpacity,
            ),
          ],
        );
      },
    );
  }

  Widget _buildBackgroundFitPicker(BuildContext context) {
    return ValueListenableBuilder<HomeBackgroundFit>(
      valueListenable: HomeController.instance.backgroundFit,
      builder: (context, fit, _) {
        return ListTile(
          leading: const Icon(Icons.fit_screen_outlined),
          title: const Text('图片适应方式'),
          subtitle: const Text('控制背景图铺满、完整显示或拉伸方式'),
          trailing: DropdownButton<HomeBackgroundFit>(
            value: fit,
            underline: const SizedBox.shrink(),
            items: HomeBackgroundFit.values
                .map(
                  (item) =>
                      DropdownMenuItem(value: item, child: Text(item.label)),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              HomeController.instance.setBackgroundFit(value);
            },
          ),
        );
      },
    );
  }

  Widget _buildBackgroundPositionControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '在上方首页可见区域框中拖动图片调整位置，双指捏合调整缩放',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => HomeController.instance.setBackgroundAlignment(
              Alignment.center,
            ),
            icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
            label: const Text('居中'),
          ),
        ],
      ),
    );
  }

  // --- Shader ---

  Widget _buildFilterSection(BuildContext context, TextTheme textTheme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Row(
              children: [
                Text('Shader', style: textTheme.titleSmall),
                const SizedBox(width: 8),
                Chip(
                  label: const Text('性能开销大'),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.72),
                  labelStyle: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: HomeController.instance.shaderEnabled,
            builder: (context, shaderEnabled, _) {
              return Column(
                children: [
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.auto_awesome_outlined),
                    title: const Text('启用背景 Shader'),
                    subtitle: const Text('对背景图进行 GPU 纹理重采样与风格化渲染'),
                    value: shaderEnabled,
                    onChanged: HomeController.instance.setShaderEnabled,
                  ),
                  if (shaderEnabled) ...[
                    _buildShaderModePicker(context, textTheme),
                    const ShaderAnimationSpeedSlider(),
                    const ShaderStrengthSlider(),
                    const ShaderOpacitySlider(),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildShaderModePicker(BuildContext context, TextTheme textTheme) {
    return ValueListenableBuilder<HomeShaderMode>(
      valueListenable: HomeController.instance.shaderMode,
      builder: (context, shaderMode, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('Shader 模式', style: textTheme.bodySmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SegmentedButton<HomeShaderMode>(
                segments: const [
                  ButtonSegment(
                    value: HomeShaderMode.glass,
                    icon: Icon(Icons.blur_on_outlined, size: 18),
                    label: Text('玻璃背景'),
                  ),
                  ButtonSegment(
                    value: HomeShaderMode.ribbon,
                    icon: Icon(Icons.waves_outlined, size: 18),
                    label: Text('流光丝带'),
                  ),
                  ButtonSegment(
                    value: HomeShaderMode.collage,
                    icon: Icon(Icons.auto_awesome_mosaic_outlined, size: 18),
                    label: Text('流体纹理'),
                  ),
                ],
                selected: {shaderMode},
                onSelectionChanged: (selection) {
                  HomeController.instance.setShaderMode(selection.first);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                switch (shaderMode) {
                  HomeShaderMode.ribbon =>
                    '保留原始流动丝带场，用背景图纹理为丝带着色并轻微混合主题色；动画会持续占用 GPU。',
                  HomeShaderMode.collage =>
                    '先将背景图切成细块取样，再用流体扰动场推移块状纹理，保留原图配色并产生液态形变；动画会持续占用 GPU。',
                  HomeShaderMode.glass =>
                    '将背景图作为纹理输入，柔焦雾化、轻微折射并混合当前主题色，适合搭配毛玻璃卡片。',
                },
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // --- Glass ---

  Widget _buildGlassSection(BuildContext context, TextTheme textTheme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Text('毛玻璃效果', style: textTheme.titleSmall),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: HomeController.instance.frostedGlassEnabled,
            builder: (context, glassEnabled, _) {
              return SwitchListTile.adaptive(
                secondary: const Icon(Icons.blur_on_outlined),
                title: const Text('首页卡片毛玻璃'),
                subtitle: const Text('对仪表盘卡片添加模糊效果'),
                value: glassEnabled,
                onChanged: HomeController.instance.setFrostedGlassEnabled,
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: HomeController.instance.headerGlassEnabled,
            builder: (context, headerGlass, _) {
              return SwitchListTile.adaptive(
                secondary: const Icon(Icons.blur_on_outlined),
                title: const Text('课表卡片毛玻璃'),
                subtitle: const Text('对顶部课表卡片添加模糊效果'),
                value: headerGlass,
                onChanged: HomeController.instance.setHeaderGlassEnabled,
              );
            },
          ),
          _buildGlassBlurSlider(),
          _buildGlassOpacitySlider(),
        ],
      ),
    );
  }

  Widget _buildGlassBlurSlider() {
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.glassBlur,
      builder: (context, blur, _) {
        return GlassPresetControl(
          label: '模糊强度',
          value: blur,
          min: 0,
          max: 30,
          presets: const [0, 8, 14, 20, 28],
          decimals: 0,
          suffix: '',
          onPreview: (value) {
            HomeController.instance.glassBlur.value = value;
          },
          onCommit: HomeController.instance.setGlassBlur,
        );
      },
    );
  }

  Widget _buildGlassOpacitySlider() {
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.glassOpacity,
      builder: (context, opacity, _) {
        return GlassPresetControl(
          label: '卡片透明度',
          value: opacity,
          min: 0.2,
          max: 1.0,
          presets: const [0.36, 0.52, 0.68, 0.82, 0.94],
          decimals: 0,
          suffix: '%',
          displayMultiplier: 100,
          onPreview: (value) {
            HomeController.instance.glassOpacity.value = value;
          },
          onCommit: HomeController.instance.setGlassOpacity,
        );
      },
    );
  }
}
