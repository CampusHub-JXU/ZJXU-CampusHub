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
                PlainSwitchRow(
                  switchKey: const Key('personalization_icon_follow_theme'),
                  title: '图标跟随主题色',
                  value: prefs.iconFollowThemeColor,
                  onChanged: controller.setIconFollowThemeColor,
                ),
                PlainSwitchRow(
                  switchKey: const Key('personalization_icon_dark_invert'),
                  title: '深色模式反色',
                  value: prefs.iconDarkInvert,
                  onChanged: controller.setIconDarkInvert,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '切换后系统桌面可能需要 1–2 秒刷新；自定义主题色在桌面会匹配最接近的预设色。',
                style: context.appText.meta,
              ),
            ),
          ],
        );
      },
    );
  }
}
