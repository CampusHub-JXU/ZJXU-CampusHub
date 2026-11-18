import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_preferences_controller.dart';
import '../../../core/theme/app_theme_palette.dart';
import '../../../core/theme/text_scale_controller.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/plain_list.dart';
import 'hsv_color_picker_sheet.dart';

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
            _buildModeButtons(prefs),
            const SizedBox(height: kPlainListGroupGap),
            const PlainSectionHeader('主题色彩'),
            _buildPaletteGrid(prefs),
            const SizedBox(height: kPlainListGroupGap),
            PlainListGroup(
              children: [
                PlainSwitchRow(
                  title: '纯黑模式',
                  subtitle: '深色主题使用纯黑背景，适合 OLED 屏幕省电',
                  value: prefs.pureBlack,
                  onChanged: _ctrl.setPureBlack,
                ),
                ..._buildTextScale(prefs),
              ],
            ),
            const SizedBox(height: kPlainListGroupGap),
            const PlainSectionHeader('首页卡片文字'),
            _buildHomeTextColor(prefs),
          ],
        );
      },
    );
  }

  /// 主题模式三选一：分段按钮（design-guidelines §4.6）。
  Widget _buildModeButtons(AppPreferences prefs) {
    return SegmentedButton<AppThemePreference>(
      segments: const [
        ButtonSegment(
          value: AppThemePreference.system,
          icon: Icon(Icons.sync),
          label: Text('自动'),
        ),
        ButtonSegment(
          value: AppThemePreference.light,
          icon: Icon(Icons.light_mode),
          label: Text('浅色'),
        ),
        ButtonSegment(
          value: AppThemePreference.dark,
          icon: Icon(Icons.dark_mode),
          label: Text('深色'),
        ),
      ],
      selected: {prefs.themeMode},
      onSelectionChanged: (selection) => _ctrl.setThemeMode(selection.first),
      showSelectedIcon: false,
    );
  }

  Widget _buildPaletteGrid(AppPreferences prefs) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: themePalettes.length + 1,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1.0,
      ),
      itemBuilder: (context, index) {
        if (index == themePalettes.length) {
          return _CustomPaletteButton(
            preview: previewColorsFromSeed(prefs.customSeedColor),
            selected: prefs.colorSource == AppColorPreference.custom,
            onTap: () => _openCustomColorPicker(prefs),
          );
        }
        final palette = themePalettes[index];
        final preview = previewColorsFromSeed(palette.primary);
        final selected =
            prefs.colorSource == AppColorPreference.preset &&
            prefs.paletteIndex == index;
        return _PaletteCard(
          preview: preview,
          selected: selected,
          onTap: () => _ctrl.setPaletteIndex(index),
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
        subtitle: _textScaleEnabled
            ? '在系统字体大小基础上叠加调整 · 默认 $defaultLabel'
            : '在系统字体大小基础上叠加调整 · 当前使用默认缩放 $defaultLabel',
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

  Widget _buildHomeTextColor(AppPreferences prefs) {
    return SegmentedButton<HomeTextColorPreference>(
      segments: HomeTextColorPreference.values
          .map((m) => ButtonSegment(value: m, label: Text(m.label)))
          .toList(),
      selected: {prefs.homeTextColor},
      onSelectionChanged: (selection) {
        _ctrl.setHomeTextColor(selection.first);
      },
      showSelectedIcon: false,
    );
  }

  String _formatScale(double value) => '${(value * 100).round()}%';
}

// ── Extension for label ──────────────────────────────────────────────────

extension on HomeTextColorPreference {
  String get label => switch (this) {
    HomeTextColorPreference.system => '跟随系统',
    HomeTextColorPreference.dark => '深色文字',
    HomeTextColorPreference.light => '浅色文字',
  };
}

// ── Palette Card (quartered circle preview) ───────────────────────────────

class _PaletteCard extends StatelessWidget {
  final ({Color primary, Color secondary, Color tertiary, Color surface})
  preview;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteCard({
    required this.preview,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: AppRadius.cardBorder,
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: SizedBox(
            width: 48,
            height: 48,
            child: ClipOval(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  GridView.count(
                    crossAxisCount: 2,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    children: [
                      ColoredBox(color: preview.primary),
                      ColoredBox(color: preview.tertiary),
                      ColoredBox(color: preview.secondary),
                      ColoredBox(
                        color: preview.primary.withValues(alpha: 0.45),
                      ),
                    ],
                  ),
                  if (selected)
                    const Icon(Icons.check, size: 20, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomPaletteButton extends StatelessWidget {
  final ({Color primary, Color secondary, Color tertiary, Color surface})
  preview;
  final bool selected;
  final VoidCallback onTap;

  const _CustomPaletteButton({
    required this.preview,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GestureDetector(
      key: const ValueKey('custom-theme-color-button'),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: AppRadius.cardBorder,
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: SizedBox(
            width: 54,
            height: 54,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: ClipOval(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        GridView.count(
                          crossAxisCount: 2,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          children: [
                            ColoredBox(color: preview.primary),
                            ColoredBox(color: preview.tertiary),
                            ColoredBox(color: preview.secondary),
                            ColoredBox(
                              color: preview.primary.withValues(alpha: 0.45),
                            ),
                          ],
                        ),
                        if (selected)
                          const Icon(
                            Icons.check,
                            size: 20,
                            color: Colors.white,
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLowest,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.edit_outlined,
                        color: colors.onSurfaceVariant,
                        size: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
