import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/personalization_controller.dart';
import '../../../shared/widgets/plain_list.dart';

/// Shader 参数滑条组：放在「效果」分组里，与分组内其它行共用
/// [PlainSliderRow]（标题左、数值右、滑条下挂）。回调与数值域不变。
class ShaderAnimationSpeedSlider extends StatelessWidget {
  const ShaderAnimationSpeedSlider({super.key});

  @override
  Widget build(BuildContext context) {
    return _ShaderSlider(
      sliderKey: const Key('personalization_shader_speed'),
      title: '速度',
      valueListenable: PersonalizationController.instance.shaderAnimationSpeed,
      label: (speed) => '${speed.toStringAsFixed(1)}×',
      max: 2,
      divisions: 20,
      onChanged: PersonalizationController.instance.setShaderAnimationSpeed,
    );
  }
}

/// 帧率档位滑条（30 / 45 / 60 / 90 / 120）。高于屏幕刷新率的档位等同「跟随
/// 屏幕」，数值右侧标出实际生效情况。
class ShaderFpsSlider extends StatelessWidget {
  const ShaderFpsSlider({super.key});

  @override
  Widget build(BuildContext context) {
    final steps = PersonalizationController.kShaderFpsSteps;
    final refreshRate = View.maybeOf(context)?.display.refreshRate ?? 60.0;
    return ValueListenableBuilder<int>(
      valueListenable: PersonalizationController.instance.shaderFps,
      builder: (context, fps, _) {
        final index = steps.indexOf(fps).clamp(0, steps.length - 1);
        final capped = fps > refreshRate.round();
        return PlainSliderRow(
          sliderKey: const Key('personalization_shader_fps'),
          title: '帧率',
          value: index.toDouble(),
          valueLabel: capped
              ? '$fps fps（屏幕 ${refreshRate.round()}Hz）'
              : '$fps fps',
          max: (steps.length - 1).toDouble(),
          divisions: steps.length - 1,
          onChanged: (value) => PersonalizationController.instance.setShaderFps(
            steps[value.round().clamp(0, steps.length - 1)],
          ),
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
      sliderKey: const Key('personalization_shader_strength'),
      title: '强度',
      valueListenable: PersonalizationController.instance.shaderStrength,
      label: (strength) => '${(strength * 100).round()}%',
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
      sliderKey: const Key('personalization_shader_opacity'),
      title: '叠加不透明度',
      valueListenable: PersonalizationController.instance.shaderOpacity,
      label: (opacity) => '${(opacity * 100).round()}%',
      divisions: 20,
      onChanged: PersonalizationController.instance.setShaderOpacity,
    );
  }
}

class _ShaderSlider extends StatelessWidget {
  const _ShaderSlider({
    required this.sliderKey,
    required this.title,
    required this.valueListenable,
    required this.label,
    required this.divisions,
    required this.onChanged,
    this.max = 1,
  });

  final Key sliderKey;
  final String title;
  final ValueListenable<double> valueListenable;
  final String Function(double value) label;
  final int divisions;
  final ValueChanged<double> onChanged;
  final double max;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: valueListenable,
      builder: (context, value, _) => PlainSliderRow(
        sliderKey: sliderKey,
        title: title,
        value: value,
        valueLabel: label(value),
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
  }
}
