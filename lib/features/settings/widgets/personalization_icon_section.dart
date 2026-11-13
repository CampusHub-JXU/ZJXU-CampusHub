import 'package:flutter/material.dart';

import '../../../core/theme/app_icon_style.dart';
import '../../../core/theme/app_preferences_controller.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_brand_icon.dart';
import '../../../shared/widgets/plain_list.dart';

class PersonalizationIconSection extends StatelessWidget {
  const PersonalizationIconSection({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppPreferencesController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final prefs = controller.state;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PlainSectionHeader('应用图标'),
            PlainListGroup(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: AppBrandIcon(
                      key: Key('personalization_icon_preview'),
                    ),
                  ),
                ),
                for (final style in AppIconStyle.values)
                  PlainListRow(
                    key: Key('personalization_icon_${style.name}'),
                    leading: ExcludeSemantics(
                      child: AppBrandIcon(size: 40, style: style),
                    ),
                    title: style.label,
                    onTap: () => controller.setAppIconStyle(style),
                    trailing: prefs.appIconStyle == style
                        ? Icon(
                            Icons.check,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    showChevron: false,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '「青瓷 · 黛瓦」与「跟随主题色」的深色款会随系统深/浅模式自动换色；切换后系统桌面可能需要几秒刷新，自定义主题色会匹配最接近的预设色。',
                style: context.appText.meta,
              ),
            ),
          ],
        );
      },
    );
  }
}
