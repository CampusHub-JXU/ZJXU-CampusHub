import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_preferences_controller.dart';
import '../../../core/theme/text_scale_controller.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/plain_list.dart';
import 'hsv_color_picker_sheet.dart';
import 'theme_color_list.dart';
import 'theme_mode_thumbnails.dart';

/// 「外观」页的主题区（PRD 0.7.0 §16）。
///
/// 从原 `ThemeSettingsPage` 抽出的无 Scaffold 内容块，供外观页与其他容器复用。
class ThemeSettingsSections extends StatefulWidget {
  const ThemeSettingsSections({super.key});

  @override
  State<ThemeSettingsSections> createState() => _ThemeSettingsSectionsState();
}

class _ThemeSettingsSectionsState extends State<ThemeSettingsSections> {
  bool _textScaleEnabled = false;

  AppPreferencesController get _ctrl => AppPreferencesController.instance;

  @override
  void initState() {
    super.initState();
    final current = _ctrl.state.textScale;
    _textScaleEnabled =
        (current - TextScaleController.defaultScaleFactor).abs() > 0.001;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final prefs = _ctrl.state;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PlainSectionHeader('主题模式'),
            ThemeModeThumbnails(
              selected: prefs.themeMode,
              onChanged: _ctrl.setThemeMode,
            ),
            const SizedBox(height: kPlainListGroupGap),
            const PlainSectionHeader('主题色彩'),
            ThemeColorList(
              colorSource: prefs.colorSource,
              paletteIndex: prefs.paletteIndex,
              customSeedColor: prefs.customSeedColor,
              onSelectPreset: _ctrl.setPaletteIndex,
              onTapCustom: () => _openCustomColorPicker(prefs),
            ),
            const SizedBox(height: kPlainListGroupGap),
            const PlainSectionHeader('显示与排版'),
            PlainListGroup(
              children: [
                PlainSwitchRow(
                  title: '纯黑模式',
                  subtitle: '深色主题使用纯黑背景',
                  value: prefs.pureBlack,
                  onChanged: _ctrl.setPureBlack,
                ),
                ..._buildTextScale(prefs),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _openCustomColorPicker(AppPreferences prefs) async {
    final initialColor = prefs.colorSource == AppColorPreference.custom
        ? prefs.customSeedColor
        : prefs.seedColor;
    final selected = await showHsvColorPickerSheet(
      context,
      initialColor: initialColor,
    );
    if (selected == null) return;

    await _ctrl.setCustomSeedColor(selected);
    if (!mounted) return;
    AppFeedback.toast(context, '自定义主题色已保存');
  }

  List<Widget> _buildTextScale(AppPreferences prefs) {
    final scaleFactor = prefs.textScale;
    final defaultLabel = _formatScale(TextScaleController.defaultScaleFactor);
    return [
      PlainSwitchRow(
        title: '文本缩放',
        subtitle: _textScaleEnabled ? '默认 $defaultLabel' : null,
        value: _textScaleEnabled,
        onChanged: (value) {
          setState(() => _textScaleEnabled = value);
          if (!value) {
            _ctrl.setTextScale(TextScaleController.defaultScaleFactor);
          }
        },
      ),
      if (_textScaleEnabled) ...[
        PlainSliderRow(
          title: '缩放比例',
          value: scaleFactor,
          valueLabel: _formatScale(scaleFactor),
          min: TextScaleController.minScaleFactor,
          max: TextScaleController.maxScaleFactor,
          divisions: TextScaleController.sliderDivisions,
          onChanged: _ctrl.setTextScale,
        ),
        PlainListRow(
          title: '恢复默认缩放',
          value: defaultLabel,
          showChevron: false,
          onTap: () =>
              _ctrl.setTextScale(TextScaleController.defaultScaleFactor),
        ),
      ],
    ];
  }

  String _formatScale(double value) => '${(value * 100).round()}%';
}
