import 'package:flutter/material.dart';

import '../../shared/widgets/app_app_bar.dart';
import 'widgets/appearance_preview.dart';
import 'widgets/personalization_background_section.dart';
import 'widgets/personalization_glass_section.dart';
import 'widgets/personalization_home_section.dart';
import 'widgets/personalization_shader_section.dart';

/// 首页与界面个性化设置（背景、着色器、材质与显示选项）。
class PersonalizationPage extends StatelessWidget {
  const PersonalizationPage({super.key, this.homeSceneBuilder});

  /// 真实首页场景构建器（app 层注入 `HomeSurfaceScene`）。
  final WidgetBuilder? homeSceneBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(title: const Text('个性化'), leading: const BackButton()),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: AppearancePreview(
              maxHeight: 320,
              homeSceneBuilder: homeSceneBuilder,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: const [
                PersonalizationBackgroundSection(),
                SizedBox(height: 16),
                PersonalizationShaderSection(),
                SizedBox(height: 16),
                PersonalizationGlassSection(),
                SizedBox(height: 16),
                PersonalizationHomeSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
