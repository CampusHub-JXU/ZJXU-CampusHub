import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';

import '../../app/app_preferences_controller.dart';
import '../../app/text_scale_controller.dart';
import '../../core/theme/app_theme_palette.dart';
import 'widgets/hsv_color_picker_sheet.dart';
import '../../shared/widgets/app_app_bar.dart';

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
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
        return Scaffold(
          appBar: AppAppBar(
            title: const Text('主题'),
            leading: const BackButton(),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              // ── 主题模式 ──
              const _SectionTitle(
                icon: Icons.settings_brightness,
                title: '主题模式',
              ),
              const SizedBox(height: 8),
              _buildModeButtons(prefs),

              const SizedBox(height: 32),
              // ── 主题色彩 ──
              const _SectionTitle(icon: Icons.palette_outlined, title: '主题色彩'),
              const SizedBox(height: 8),
              _buildPaletteGrid(prefs),

              const SizedBox(height: 32),
              // ── 纯黑模式 ──
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.contrast),
                title: const Text('纯黑模式'),
                subtitle: const Text('深色主题使用纯黑背景，适合 OLED 屏幕省电'),
                value: prefs.pureBlack,
                onChanged: _ctrl.setPureBlack,
              ),

              const SizedBox(height: 8),
              // ── 强调色按钮样式 ──
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.smart_button_outlined),
                title: const Text('柔和强调色按钮'),
                subtitle: const Text('强调按钮使用主题柔和色块，降低视觉强度'),
                value: prefs.filledButtonSoftStyle,
                onChanged: _ctrl.setFilledButtonSoftStyle,
              ),

              const SizedBox(height: 8),
              // ── 文本缩放 ──
              _buildTextScale(prefs),

              const SizedBox(height: 32),
              // ── 首页卡片文字 ──
              const _SectionTitle(
                icon: Icons.format_color_text_outlined,
                title: '首页卡片文字',
              ),
              const SizedBox(height: 8),
              _buildHomeTextColor(prefs),

              const SizedBox(height: 40),
            ],
          ),
        );
      },
    );
  }

  Widget _buildModeButtons(AppPreferences prefs) {
    return Row(
      children: [
        Expanded(
          child: _ModeButton(
            icon: Icons.sync,
            label: '自动',
            selected: prefs.themeMode == AppThemePreference.system,
            onTap: () => _ctrl.setThemeMode(AppThemePreference.system),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ModeButton(
            icon: Icons.light_mode,
            label: '浅色',
            selected: prefs.themeMode == AppThemePreference.light,
            onTap: () => _ctrl.setThemeMode(AppThemePreference.light),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ModeButton(
            icon: Icons.dark_mode,
            label: '深色',
            selected: prefs.themeMode == AppThemePreference.dark,
            onTap: () => _ctrl.setThemeMode(AppThemePreference.dark),
          ),
        ),
      ],
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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('自定义主题色已保存')));
  }

  Widget _buildTextScale(AppPreferences prefs) {
    final scaleFactor = prefs.textScale;
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.text_fields),
          title: const Text('文本缩放'),
          subtitle: Text(
            _textScaleEnabled
                ? '${_formatScale(scaleFactor)} · 默认 ${_formatScale(TextScaleController.defaultScaleFactor)}'
                : '在系统字体大小基础上叠加调整 · 当前使用默认缩放 ${_formatScale(TextScaleController.defaultScaleFactor)}',
          ),
          value: _textScaleEnabled,
          onChanged: (value) {
            setState(() => _textScaleEnabled = value);
            if (!value) {
              _ctrl.setTextScale(TextScaleController.defaultScaleFactor);
            }
          },
        ),
        if (_textScaleEnabled) ...[
          const SizedBox(height: 4),
          Slider.adaptive(
            min: TextScaleController.minScaleFactor,
            max: TextScaleController.maxScaleFactor,
            divisions: TextScaleController.sliderDivisions,
            label: _formatScale(scaleFactor),
            value: scaleFactor,
            onChanged: _ctrl.setTextScale,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatScale(TextScaleController.minScaleFactor),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                TextButton(
                  onPressed: () => _ctrl.setTextScale(
                    TextScaleController.defaultScaleFactor,
                  ),
                  child: const Text('恢复默认'),
                ),
                Text(
                  _formatScale(TextScaleController.maxScaleFactor),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ],
    );
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

// ── Section Title ────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionTitle({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, color: cs.onSurfaceVariant, size: 16),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

// ── Mode Button ──────────────────────────────────────────────────────────

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.icon,
    required this.label,
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
        height: 64,
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer.withValues(alpha: 0.5)
              : colors.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: AppRadius.cardBorder,
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? colors.primary : colors.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
