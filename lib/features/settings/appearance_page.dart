import 'package:flutter/material.dart';

import '../../shared/widgets/app_app_bar.dart';
import 'widgets/appearance_preview.dart';
import 'widgets/personalization_background_section.dart';
import 'widgets/personalization_glass_section.dart';
import 'widgets/personalization_home_section.dart';
import 'widgets/personalization_shader_section.dart';
import 'widgets/theme_settings_sections.dart';

/// 外观与个性化（PRD 0.7.0 §15/§16）。
///
/// 原「主题与外观」+「首页个性化」合并页：顶部真实比例预览，下方依次是主题、
/// 首页、背景、Shader、材质设置。
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('外观与个性化'),
        leading: const BackButton(),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: AppearancePreview(maxHeight: 320),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: const [
                ThemeSettingsSections(),
                SizedBox(height: 24),
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
