import 'package:flutter/material.dart';

import '../../../core/theme/glass_style_controller.dart';
import '../../../core/theme/personalization_controller.dart';
import '../../../shared/widgets/plain_list.dart';
import 'shader_tuning_controls.dart';

/// 个性化 — 「效果」分组：亚克力材质、流体 Shader（含参数滑条）、
/// 课表卡片毛玻璃。
///
/// 全局只保留一个「亚克力材质」开关（默认开启，关闭为实色），由
/// [GlassStyleController] 统一存储并被所有表面组件消费；风格切换与
/// 模糊/透明度滑条已下线。「课表卡片毛玻璃」是首页头卡的独立布局开关，
/// 仍归 [PersonalizationController]。Shader 仅保留流体纹理一种模式。
class PersonalizationEffectsSection extends StatelessWidget {
  const PersonalizationEffectsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final style = GlassStyleController.instance;
    final controller = PersonalizationController.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlainSectionHeader('效果'),
        PlainListGroup(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: style.enabled,
              builder: (context, acrylicEnabled, _) => PlainSwitchRow(
                switchKey: const Key('personalization_acrylic'),
                title: '亚克力材质',
                subtitle: '顶栏、底部导航与功能卡片模糊透出壁纸',
                value: acrylicEnabled,
                onChanged: style.setEnabled,
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: controller.shaderEnabled,
              builder: (context, shaderEnabled, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlainSwitchRow(
                    switchKey: const Key('personalization_shader'),
                    title: '流体 Shader',
                    titleBadge: '耗电',
                    subtitle: '对壁纸做块状取样与流体扰动，持续占用 GPU',
                    value: shaderEnabled,
                    onChanged: controller.setShaderEnabled,
                  ),
                  if (shaderEnabled) ...const [
                    ShaderAnimationSpeedSlider(),
                    ShaderStrengthSlider(),
                    ShaderOpacitySlider(),
                  ],
                ],
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: controller.headerGlassEnabled,
              builder: (context, headerGlass, _) => PlainSwitchRow(
                switchKey: const Key('personalization_header_glass'),
                title: '课表卡片毛玻璃',
                subtitle: '壁纸之上时对首页顶部课表卡片添加模糊',
                value: headerGlass,
                onChanged: controller.setHeaderGlassEnabled,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
