import 'package:flutter/material.dart';

import '../../home/home_controller.dart';
import 'glass_preset_control.dart';

/// 首页个性化 — 毛玻璃 section（PRD FR-4 拆分）。
class PersonalizationGlassSection extends StatelessWidget {
  const PersonalizationGlassSection({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
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
