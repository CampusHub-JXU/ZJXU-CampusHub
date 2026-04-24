import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/app_theme_controller.dart';
import '../home/home_controller.dart';
import '../home/widgets/home_background_layer.dart';

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
                _buildAppThemeSection(context, textTheme),
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
                          borderRadius: BorderRadius.circular(18),
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
                                    useAsyncFilter: false,
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
                                        borderRadius: BorderRadius.circular(8),
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
                        await HomeController.instance.setColorFilterEnabled(
                          false,
                        );
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

  // --- App Theme ---

  Widget _buildAppThemeSection(BuildContext context, TextTheme textTheme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Text('应用主题', style: textTheme.titleSmall),
          ),
          ValueListenableBuilder<AppThemeSeedMode>(
            valueListenable: AppThemeController.instance.seedMode,
            builder: (context, seedMode, _) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SegmentedButton<AppThemeSeedMode>(
                  segments: const [
                    ButtonSegment(
                      value: AppThemeSeedMode.brandRed,
                      icon: Icon(Icons.school_outlined, size: 18),
                      label: Text('默认红色'),
                    ),
                    ButtonSegment(
                      value: AppThemeSeedMode.monet,
                      icon: Icon(Icons.auto_awesome_outlined, size: 18),
                      label: Text('莫奈取色'),
                    ),
                  ],
                  selected: {seedMode},
                  onSelectionChanged: (selection) async {
                    await AppThemeController.instance.setSeedMode(
                      selection.first,
                    );
                  },
                ),
              );
            },
          ),
          _buildHomeTextColorModePicker(context),
          ValueListenableBuilder<bool>(
            valueListenable: AppThemeController.instance.uniformIconColor,
            builder: (context, uniformIconColor, _) {
              return SwitchListTile.adaptive(
                secondary: const Icon(Icons.format_color_fill_outlined),
                title: const Text('统一入口图标颜色'),
                subtitle: const Text('首页、功能页和我的页图标跟随当前主题色'),
                value: uniformIconColor,
                onChanged: AppThemeController.instance.setUniformIconColor,
              );
            },
          ),
          _buildThemeSeedColorTile(),
        ],
      ),
    );
  }

  Widget _buildHomeTextColorModePicker(BuildContext context) {
    return ValueListenableBuilder<HomeTextColorMode>(
      valueListenable: AppThemeController.instance.homeTextColorMode,
      builder: (context, mode, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.format_color_text_outlined),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '首页卡片字体颜色',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '背景较暗或偏花时，可强制使用浅色文字',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<HomeTextColorMode>(
                  segments: HomeTextColorMode.values
                      .map(
                        (item) =>
                            ButtonSegment(value: item, label: Text(item.label)),
                      )
                      .toList(),
                  selected: {mode},
                  onSelectionChanged: (selection) {
                    AppThemeController.instance.setHomeTextColorMode(
                      selection.first,
                    );
                  },
                  showSelectedIcon: false,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildThemeSeedColorTile() {
    return ValueListenableBuilder<Color>(
      valueListenable: AppThemeController.instance.seedColor,
      builder: (context, seedColor, _) {
        return ValueListenableBuilder<AppThemeSeedMode>(
          valueListenable: AppThemeController.instance.seedMode,
          builder: (context, seedMode, _) {
            return ValueListenableBuilder<int>(
              valueListenable: AppThemeController.instance.monetSeedIndex,
              builder: (context, monetSeedIndex, _) {
                return ValueListenableBuilder<List<Color>?>(
                  valueListenable: HomeController.instance.monetColors,
                  builder: (context, monetColors, _) {
                    final colors =
                        monetColors ??
                        HomeController.instance.cachedMonetColors;
                    return Column(
                      children: [
                        ListTile(
                          leading: CircleAvatar(backgroundColor: seedColor),
                          title: const Text('当前主题色'),
                          subtitle: Text(
                            seedMode == AppThemeSeedMode.monet
                                ? '从首页背景图提取 Material 3 主题色，可在下方切换候选色'
                                : '使用嘉大默认红色主题',
                          ),
                          trailing: seedMode == AppThemeSeedMode.monet
                              ? IconButton(
                                  tooltip: '重新取色',
                                  icon: const Icon(Icons.refresh_outlined),
                                  onPressed: AppThemeController
                                      .instance
                                      .refreshMonetSeed,
                                )
                              : null,
                        ),
                        if (seedMode == AppThemeSeedMode.monet &&
                            colors != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  for (var i = 0; i < colors.length; i++)
                                    ChoiceChip(
                                      label: Text('色 ${i + 1}'),
                                      selected: i == monetSeedIndex,
                                      avatar: CircleAvatar(
                                        backgroundColor: colors[i],
                                      ),
                                      onSelected: (_) {
                                        AppThemeController.instance
                                            .setMonetSeedIndex(i);
                                      },
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
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

  // --- Filter ---

  Widget _buildFilterSection(BuildContext context, TextTheme textTheme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Text('色彩滤镜', style: textTheme.titleSmall),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: HomeController.instance.colorFilterEnabled,
            builder: (context, filterEnabled, _) {
              return Column(
                children: [
                  SwitchListTile.adaptive(
                    secondary: const Icon(Icons.color_lens_outlined),
                    title: const Text('启用色彩滤镜'),
                    subtitle: const Text('对背景图进行 RGB 色彩变换'),
                    value: filterEnabled,
                    onChanged: HomeController.instance.setColorFilterEnabled,
                  ),
                  if (filterEnabled) ...[
                    _buildFilterModePicker(context, textTheme),
                    _buildFilterStrengthSlider(context),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFilterModePicker(BuildContext context, TextTheme textTheme) {
    return ValueListenableBuilder<HomeFilterMode>(
      valueListenable: HomeController.instance.filterMode,
      builder: (context, filterMode, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('滤镜模式', style: textTheme.bodySmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SegmentedButton<HomeFilterMode>(
                segments: const [
                  ButtonSegment(
                    value: HomeFilterMode.brand,
                    icon: Icon(Icons.palette_outlined, size: 18),
                    label: Text('红黑白'),
                  ),
                  ButtonSegment(
                    value: HomeFilterMode.monet,
                    icon: Icon(Icons.auto_awesome_outlined, size: 18),
                    label: Text('莫奈取色'),
                  ),
                  ButtonSegment(
                    value: HomeFilterMode.custom,
                    icon: Icon(Icons.tune_outlined, size: 18),
                    label: Text('自定义'),
                  ),
                ],
                selected: {filterMode},
                onSelectionChanged: (selection) {
                  HomeController.instance.setFilterMode(selection.first);
                },
              ),
            ),
            if (filterMode == HomeFilterMode.monet)
              _buildMonetColorRow(context),
            if (filterMode == HomeFilterMode.custom)
              _buildCustomColorRow(context),
          ],
        );
      },
    );
  }

  Widget _buildFilterStrengthSlider(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.filterStrength,
      builder: (context, strength, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '滤镜强度  ${(strength * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Slider.adaptive(
              value: strength,
              min: 0.0,
              max: 0.6,
              divisions: 12,
              onChanged: HomeController.instance.setFilterStrength,
            ),
          ],
        );
      },
    );
  }

  Widget _buildMonetColorRow(BuildContext context) {
    return ValueListenableBuilder<List<Color>?>(
      valueListenable: HomeController.instance.monetColors,
      builder: (context, colors, _) {
        if (colors == null) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '正在从背景图提取颜色…',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        final extractedColors = colors.take(5).toList();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已提取颜色', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < extractedColors.length; i++) ...[
                    Expanded(
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: extractedColors[i],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.outline.withValues(alpha: 0.25),
                          ),
                        ),
                      ),
                    ),
                    if (i < extractedColors.length - 1)
                      const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCustomColorRow(BuildContext context) {
    return ValueListenableBuilder<List<Color>>(
      valueListenable: HomeController.instance.customFilterColors,
      builder: (context, colors, _) {
        final labels = ['主色', '副色', '底色'];
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            children: [
              for (var i = 0; i < 3; i++) ...[
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _pickCustomColor(context, i, colors),
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: colors[i],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.outline.withValues(alpha: 0.3),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          fontSize: 12,
                          color: colors[i].computeLuminance() > 0.5
                              ? Colors.black87
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
                if (i < 2) const SizedBox(width: 8),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickCustomColor(
    BuildContext context,
    int index,
    List<Color> currentColors,
  ) async {
    final colors = List<Color>.from(currentColors);
    final label = ['主色', '副色', '底色'][index];
    final result = await showDialog<Color>(
      context: context,
      builder: (ctx) =>
          _ColorPickerDialog(initialColor: colors[index], label: label),
    );
    if (result == null) return;
    colors[index] = result;
    await HomeController.instance.setCustomFilterColors(colors);
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
        return _GlassPresetControl(
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
        return _GlassPresetControl(
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

class _GlassPresetControl extends StatefulWidget {
  const _GlassPresetControl({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.presets,
    required this.decimals,
    required this.suffix,
    required this.onPreview,
    required this.onCommit,
    this.displayMultiplier = 1,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final List<double> presets;
  final int decimals;
  final String suffix;
  final double displayMultiplier;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommit;

  @override
  State<_GlassPresetControl> createState() => _GlassPresetControlState();
}

class _GlassPresetControlState extends State<_GlassPresetControl> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatValue(widget.value));
  }

  @override
  void didUpdateWidget(covariant _GlassPresetControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.value - oldWidget.value).abs() > 0.001) {
      final text = _formatValue(widget.value);
      if (_controller.text != text) {
        _controller.text = text;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final closest = _closestPresetIndex(widget.value);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.label}  ${_formatValue(widget.value)}${widget.suffix}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SizedBox(
                width: 76,
                child: TextField(
                  controller: _controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                  decoration: InputDecoration(
                    isDense: true,
                    suffixText: widget.suffix.isEmpty ? null : widget.suffix,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onSubmitted: _commitText,
                  onTapOutside: (_) => _commitText(_controller.text),
                ),
              ),
            ],
          ),
          Slider.adaptive(
            value: closest.toDouble(),
            min: 0,
            max: (widget.presets.length - 1).toDouble(),
            divisions: widget.presets.length - 1,
            label: '${_formatValue(widget.presets[closest])}${widget.suffix}',
            onChanged: (index) {
              final value = widget.presets[index.round()];
              widget.onPreview(value);
            },
            onChangeEnd: (index) {
              widget.onCommit(widget.presets[index.round()]);
            },
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final preset in widget.presets)
                ChoiceChip(
                  label: Text('${_formatValue(preset)}${widget.suffix}'),
                  selected: (widget.value - preset).abs() < 0.001,
                  onSelected: (_) {
                    widget.onPreview(preset);
                    widget.onCommit(preset);
                  },
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }

  int _closestPresetIndex(double value) {
    var closest = 0;
    var diff = double.infinity;
    for (var i = 0; i < widget.presets.length; i++) {
      final itemDiff = (widget.presets[i] - value).abs();
      if (itemDiff < diff) {
        closest = i;
        diff = itemDiff;
      }
    }
    return closest;
  }

  String _formatValue(double value) {
    final displayValue = value * widget.displayMultiplier;
    return widget.decimals == 0
        ? displayValue.round().toString()
        : displayValue.toStringAsFixed(widget.decimals);
  }

  void _commitText(String text) {
    final parsed = double.tryParse(text.trim());
    if (parsed == null) {
      _controller.text = _formatValue(widget.value);
      return;
    }
    final rawValue = (parsed / widget.displayMultiplier).clamp(
      widget.min,
      widget.max,
    );
    widget.onPreview(rawValue);
    widget.onCommit(rawValue);
  }
}

// --- Color Picker Dialog (moved from settings_page.dart) ---

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initialColor, required this.label});
  final Color initialColor;
  final String label;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late double _hue;
  late double _saturation;
  late double _value;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initialColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
  }

  Color get _color => HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  static const _presets = [
    Color(0xFF8B1A2D),
    Color(0xFF1A8B6B),
    Color(0xFF1A3B8B),
    Color(0xFF8B6B1A),
    Color(0xFF5A1A8B),
    Color(0xFF1A8B8B),
    Colors.black,
    Colors.white,
    Color(0xFF666666),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('选择${widget.label}'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildSlider(
              '色相',
              _hue,
              0,
              360,
              (v) => setState(() => _hue = v),
              gradient: LinearGradient(
                colors: [
                  for (var i = 0; i <= 360; i += 30)
                    HSVColor.fromAHSV(1, i.toDouble(), 1, 1).toColor(),
                ],
              ),
            ),
            _buildSlider(
              '饱和',
              _saturation,
              0,
              1,
              (v) => setState(() => _saturation = v),
              activeColor: HSVColor.fromAHSV(1, _hue, 1, _value).toColor(),
            ),
            _buildSlider(
              '明度',
              _value,
              0,
              1,
              (v) => setState(() => _value = v),
              activeColor: HSVColor.fromAHSV(1, _hue, _saturation, 1).toColor(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presets.map((c) {
                final selected = c.toARGB32() == _color.toARGB32();
                return GestureDetector(
                  onTap: () {
                    final hsv = HSVColor.fromColor(c);
                    setState(() {
                      _hue = hsv.hue;
                      _saturation = hsv.saturation;
                      _value = hsv.value;
                    });
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.withValues(alpha: 0.3),
                        width: selected ? 2.5 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    Gradient? gradient,
    Color? activeColor,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: gradient != null
              ? ShaderMask(
                  shaderCallback: (bounds) => gradient.createShader(bounds),
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    onChanged: onChanged,
                    activeColor: Colors.white,
                    inactiveColor: Colors.grey.withValues(alpha: 0.3),
                  ),
                )
              : Slider(
                  value: value,
                  min: min,
                  max: max,
                  activeColor: activeColor,
                  onChanged: onChanged,
                ),
        ),
      ],
    );
  }
}
