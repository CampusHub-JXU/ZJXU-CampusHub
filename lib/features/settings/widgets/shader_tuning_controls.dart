import 'package:flutter/material.dart';

import '../../home/home_controller.dart';

class ShaderAnimationSpeedSlider extends StatelessWidget {
  const ShaderAnimationSpeedSlider({super.key});

  @override
  Widget build(BuildContext context) {
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '动画速度  ${speed.toStringAsFixed(1)}x',
                    style: Theme.of(context).textTheme.bodySmall,
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
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.shaderStrength,
      builder: (context, strength, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Shader 强度  ${(strength * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
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
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.shaderOpacity,
      builder: (context, opacity, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Text(
                'Shader 透明度  ${(opacity * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
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
