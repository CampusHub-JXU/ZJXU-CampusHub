import 'package:material_ui/material_ui.dart';

import '../../../core/theme/personalization_controller.dart';
import '../../../shared/widgets/plain_list.dart';
import 'shader_tuning_controls.dart';

/// 个性化 — 「效果」分组：只保留流体 Shader 总开关。
///
/// 亚克力材质始终开启（见 GlassStyleController），「亚克力材质」、只影响
/// 预览的「课表卡片毛玻璃」与「磨砂闪粉」开关均已下线。Shader 仅保留
/// 流体纹理一种模式。参数滑条（帧率/速度/强度/不透明度）默认不出现在
/// UI 上（[showSliders] 默认 false），控制器字段不动，日后需要再放开。
class PersonalizationEffectsSection extends StatelessWidget {
  const PersonalizationEffectsSection({super.key, this.showSliders = false});

  /// 是否展示 Shader 参数滑条；默认隐藏，仅保留总开关。
  final bool showSliders;

  @override
  Widget build(BuildContext context) {
    final controller = PersonalizationController.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlainSectionHeader('效果'),
        PlainListGroup(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: controller.shaderEnabled,
              builder: (context, shaderEnabled, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlainSwitchRow(
                    switchKey: const Key('personalization_shader'),
                    title: '流体 Shader',
                    titleBadge: '耗电',
                    value: shaderEnabled,
                    onChanged: controller.setShaderEnabled,
                  ),
                  if (showSliders && shaderEnabled) ...const [
                    ShaderFpsSlider(),
                    ShaderAnimationSpeedSlider(),
                    ShaderStrengthSlider(),
                    ShaderOpacitySlider(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
