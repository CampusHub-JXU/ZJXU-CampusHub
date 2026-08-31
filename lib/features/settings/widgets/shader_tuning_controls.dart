import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/personalization_controller.dart';

/// Shader 参数滑条组：与平面化分组卡同族——顶部 hairline 分隔 +
/// 13/onSurfaceVariant 标签，回调与数值域保持不变。
class ShaderAnimationSpeedSlider extends StatelessWidget {
  const ShaderAnimationSpeedSlider({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HomeShaderMode>(
      valueListenable: PersonalizationController.instance.shaderMode,
      builder: (context, shaderMode, _) {
        if (shaderMode == HomeShaderMode.glass) {
          return const SizedBox.shrink();
        }
        return _ShaderSlider(
          valueListenable:
              PersonalizationController.instance.shaderAnimationSpeed,
          label: (speed) => '动画速度  ${speed.toStringAsFixed(1)}x',
          max: 2,
          divisions: 20,
          onChanged: PersonalizationController.instance.setShaderAnimationSpeed,
        );
      },
    );
  }
}

class ShaderStrengthSlider extends StatelessWidget {
  const ShaderStrengthSlider({super.key});

  @override
  Widget build(BuildContext context) {
    return _ShaderSlider(
      valueListenable: PersonalizationController.instance.shaderStrength,
      label: (strength) => 'Shader 强度  ${(strength * 100).round()}%',
      divisions: 10,
      onChanged: PersonalizationController.instance.setShaderStrength,
    );
  }
}

class ShaderOpacitySlider extends StatelessWidget {
  const ShaderOpacitySlider({super.key});

  @override
  Widget build(BuildContext context) {
    return _ShaderSlider(
      valueListenable: PersonalizationController.instance.shaderOpacity,
      label: (opacity) => 'Shader 透明度  ${(opacity * 100).round()}%',
      divisions: 20,
      onChanged: PersonalizationController.instance.setShaderOpacity,
    );
  }
}

class _ShaderSlider extends StatelessWidget {
  const _ShaderSlider({
    required this.valueListenable,
    required this.label,
    required this.divisions,
    required this.onChanged,
    this.max = 1,
  });

  final ValueListenable<double> valueListenable;
  final String Function(double value) label;
  final int divisions;
  final ValueChanged<double> onChanged;
  final double max;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: valueListenable,
      builder: (context, value, _) {
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
                label(value),
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
            Slider.adaptive(
              value: value,
              min: 0,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ],
        );
      },
    );
  }
}
