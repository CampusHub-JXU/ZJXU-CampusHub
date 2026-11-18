import 'package:material_ui/material_ui.dart';

import '../../../core/theme/personalization_controller.dart';
import '../../../shared/widgets/plain_list.dart';
import 'shader_tuning_controls.dart';

/// 个性化 — 「效果」分组：只剩流体 Shader（含参数滑条）。
///
/// 亚克力材质始终开启（见 GlassStyleController），「亚克力材质」、只影响
/// 预览的「课表卡片毛玻璃」与「磨砂闪粉」开关均已下线。Shader 仅保留
/// 流体纹理一种模式。
class PersonalizationEffectsSection extends StatelessWidget {
  const PersonalizationEffectsSection({super.key});

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
                    subtitle:
                        '用壁纸取色（未设壁纸时用主题色）生成流体背景，设了壁纸会替换壁纸画面；后台、被遮挡或系统关闭动画时自动暂停',
                    value: shaderEnabled,
                    onChanged: controller.setShaderEnabled,
                  ),
                  if (shaderEnabled) ...const [
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
