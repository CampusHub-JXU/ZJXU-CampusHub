import 'package:flutter/material.dart';

import '../../home/home_controller.dart';

/// Shader 参数滑条组：与平面化分组卡同族——顶部 hairline 分隔 +
/// 13/onSurfaceVariant 标签，回调与数值域保持不变。
class ShaderAnimationSpeedSlider extends StatelessWidget {
  const ShaderAnimationSpeedSlider({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<HomeShaderMode>(
      valueListenable: HomeController.instance.shaderMode,
      builder: (context, shaderMode, _) {
        if (shaderMode == HomeShaderMode.glass) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<double>(
          valueListenable: HomeController.instance.shaderAnimationSpeed,
          builder: (context, speed, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  color: cs.outlineVariant.withValues(alpha: 0.35),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Text(
                    '动画速度  ${speed.toStringAsFixed(1)}x',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ),
                Slider.adaptive(
                  value: speed,
                  min: 0.0,
                  max: 2.0,
                  divisions: 20,
                  onChanged: HomeController.instance.setShaderAnimationSpeed,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class ShaderStrengthSlider extends StatelessWidget {
  const ShaderStrengthSlider({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.shaderStrength,
      builder: (context, strength, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(
              height: 1,
              thickness: 1,
              indent: 16,
              color: cs.outlineVariant.withValues(alpha: 0.35),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                'Shader 强度  ${(strength * 100).round()}%',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
            Slider.adaptive(
              value: strength,
              min: 0.0,
              max: 1.0,
              divisions: 10,
              onChanged: HomeController.instance.setShaderStrength,
            ),
          ],
        );
      },
    );
  }
}

class ShaderOpacitySlider extends StatelessWidget {
  const ShaderOpacitySlider({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.shaderOpacity,
      builder: (context, opacity, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(
              height: 1,
              thickness: 1,
              indent: 16,
              color: cs.outlineVariant.withValues(alpha: 0.35),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                'Shader 透明度  ${(opacity * 100).round()}%',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
            Slider.adaptive(
              value: opacity,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: HomeController.instance.setShaderOpacity,
            ),
          ],
        );
      },
    );
  }
}
