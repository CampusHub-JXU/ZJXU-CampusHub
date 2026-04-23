import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../home/home_controller.dart';

class PersonalizationPage extends StatelessWidget {
  const PersonalizationPage({super.key});

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

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已设置首页背景')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选择图片失败，请稍后重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('首页个性化')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPreviewSection(context),
          const SizedBox(height: 16),
          _buildBackgroundSection(context, textTheme),
          const SizedBox(height: 16),
          _buildFilterSection(context, textTheme),
          const SizedBox(height: 16),
          _buildGlassSection(context, textTheme),
        ],
      ),
    );
  }

  // --- Preview ---

  Widget _buildPreviewSection(BuildContext context) {
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
                  Icon(Icons.wallpaper_outlined,
                      size: 36,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text('暂未设置背景图片',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13)),
                ],
              ),
            ),
          );
        }

        return ValueListenableBuilder<bool>(
          valueListenable: HomeController.instance.colorFilterEnabled,
          builder: (context, filterEnabled, _) {
            return ValueListenableBuilder<double>(
              valueListenable: HomeController.instance.filterStrength,
              builder: (context, strength, _) {
                return ValueListenableBuilder<double>(
                  valueListenable: HomeController.instance.backgroundOpacity,
                  builder: (context, opacity, _) {
                    final matrix = filterEnabled
                        ? HomeController.instance
                            .buildFilterMatrixSync(strength)
                        : null;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Opacity(
                                opacity: opacity,
                                child: matrix != null
                                    ? ColorFiltered(
                                        colorFilter:
                                            ColorFilter.matrix(matrix),
                                        child: _buildImage(context, bgPath),
                                      )
                                    : _buildImage(context, bgPath),
                              ),
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color:
                                        Colors.black.withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text('预览',
                                      style: TextStyle(
                                          color: Colors.white, fontSize: 11)),
                                ),
                              ),
                            ],
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

  Widget _buildImage(BuildContext context, String path) {
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
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
                    subtitle: Text(
                        bgPath != null ? '已设置自定义背景' : '未设置，使用默认背景'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickHomeBackgroundImage(context),
                  ),
                  if (bgPath != null) ...[
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('移除背景图片'),
                      onTap: () {
                        HomeController.instance.clearBackgroundImage();
                        HomeController.instance.setColorFilterEnabled(false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已移除首页背景')),
                          );
                        }
                      },
                    ),
                    _buildBackgroundOpacitySlider(),
                    _buildBackgroundAlignmentPicker(context),
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
              child: Text('透明度  ${(opacity * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall),
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

  Widget _buildBackgroundAlignmentPicker(BuildContext context) {
    const alignments = [
      Alignment.topLeft, Alignment.topCenter, Alignment.topRight,
      Alignment.centerLeft, Alignment.center, Alignment.centerRight,
      Alignment.bottomLeft, Alignment.bottomCenter, Alignment.bottomRight,
    ];
    const labels = [
      '↖', '↑', '↗',
      '←', '·', '→',
      '↙', '↓', '↘',
    ];
    return ValueListenableBuilder<Alignment>(
      valueListenable: HomeController.instance.backgroundAlignment,
      builder: (context, alignment, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('图片位置', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 1.8,
                children: List.generate(9, (i) {
                  final selected = alignment == alignments[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => HomeController.instance
                        .setBackgroundAlignment(alignments[i]),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                                  .colorScheme
                                  .outline
                                  .withValues(alpha: 0.2),
                          width: selected ? 2 : 1,
                        ),
                        color: selected
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.08)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Text(labels[i],
                          style: TextStyle(
                              fontSize: 16,
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                    ),
                  );
                }),
              ),
            ],
          ),
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
              child: Text('滤镜强度  ${(strength * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall),
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
                          color: Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.3),
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
      builder: (ctx) => _ColorPickerDialog(
        initialColor: colors[index],
        label: label,
      ),
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
        ],
      ),
    );
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

  Color get _color =>
      HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

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
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildSlider(
                '色相', _hue, 0, 360, (v) => setState(() => _hue = v),
                gradient: LinearGradient(
                  colors: [
                    for (var i = 0; i <= 360; i += 30)
                      HSVColor.fromAHSV(1, i.toDouble(), 1, 1).toColor()
                  ],
                )),
            _buildSlider(
                '饱和',
                _saturation,
                0,
                1,
                (v) => setState(() => _saturation = v),
                activeColor:
                    HSVColor.fromAHSV(1, _hue, 1, _value).toColor()),
            _buildSlider(
                '明度',
                _value,
                0,
                1,
                (v) => setState(() => _value = v),
                activeColor:
                    HSVColor.fromAHSV(1, _hue, _saturation, 1).toColor()),
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
            child: Text(label, style: const TextStyle(fontSize: 13))),
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
