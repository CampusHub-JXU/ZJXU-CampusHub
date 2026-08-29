import 'package:flutter/material.dart';

import '../../../core/theme/glass_style_controller.dart';
import '../../home/home_controller.dart';
import 'glass_preset_control.dart';

/// 首页个性化 — 玻璃材质 section。
///
/// 参数（开关/模糊强度/透明度）为全局材质设置，由
/// [GlassStyleController] 统一存储并被所有玻璃组件消费；
/// 「课表卡片毛玻璃」是首页头卡的独立布局开关，仍归 HomeController。
class PersonalizationGlassSection extends StatelessWidget {
  const PersonalizationGlassSection({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final style = GlassStyleController.instance;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
            child: Text('玻璃材质', style: textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              // 与新语义同步：模糊强度滑条是全局唯一输入源，
              // 同时作用于顶栏/底栏/弹层/玻璃卡片。
              '全局材质参数：模糊强度与透明度统一作用于顶栏、底部导航、弹层与玻璃卡片',
              style: textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: style.enabled,
            builder: (context, glassEnabled, _) {
              return SwitchListTile.adaptive(
                secondary: const Icon(Icons.blur_on_outlined),
                title: const Text('玻璃材质（全局）'),
                subtitle: const Text('关闭后所有玻璃表面降级为实色，低端机更流畅'),
                value: glassEnabled,
                onChanged: (value) => style.setEnabled(value),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: HomeController.instance.headerGlassEnabled,
            builder: (context, headerGlass, _) {
              return SwitchListTile.adaptive(
                secondary: const Icon(Icons.blur_on_outlined),
                title: const Text('课表卡片毛玻璃'),
                subtitle: const Text('背景图之上时对顶部课表卡片添加模糊'),
                value: headerGlass,
                onChanged: HomeController.instance.setHeaderGlassEnabled,
              );
            },
          ),
          _buildGlassBlurSlider(style),
          _buildGlassOpacitySlider(style),
        ],
      ),
    );
  }

  Widget _buildGlassBlurSlider(GlassStyleController style) {
    return ValueListenableBuilder<double>(
      valueListenable: style.blurSigma,
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
            style.blurSigma.value = value;
          },
          onCommit: style.setBlurSigma,
        );
      },
    );
  }

  Widget _buildGlassOpacitySlider(GlassStyleController style) {
    return ValueListenableBuilder<double>(
      valueListenable: style.tintOpacity,
      builder: (context, opacity, _) {
        return GlassPresetControl(
          label: '玻璃透明度',
          value: opacity,
          min: 0.2,
          max: 1.0,
          presets: const [0.36, 0.52, 0.68, 0.82, 0.94],
          decimals: 0,
          suffix: '%',
          displayMultiplier: 100,
          onPreview: (value) {
            style.tintOpacity.value = value;
          },
          onCommit: style.setTintOpacity,
        );
      },
    );
  }
}
