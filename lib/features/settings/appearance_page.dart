import 'package:flutter/material.dart';

import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/plain_list.dart';
import 'widgets/appearance_preview.dart';
import 'widgets/theme_settings_sections.dart';

/// 外观设置（主题模式、强调色、字体大小与暗色适配）。
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, this.homeSceneBuilder});

  /// 真实首页场景构建器（app 层注入 `HomeSurfaceScene`）。
  final WidgetBuilder? homeSceneBuilder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(title: const Text('外观'), leading: const BackButton()),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPlainListGutter,
              12,
              kPlainListGutter,
              8,
            ),
            child: AppearancePreview(
              maxHeight: 320,
              homeSceneBuilder: homeSceneBuilder,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                kPlainListGutter,
                8,
                kPlainListGutter,
                24,
              ),
              children: const [ThemeSettingsSections()],
            ),
          ),
        ],
      ),
    );
  }
}
