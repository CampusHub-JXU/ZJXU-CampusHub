import 'package:flutter/material.dart';

import '../../app/app_theme_controller.dart';
import '../../app/text_scale_controller.dart';
import '../../app/theme_mode_controller.dart';

class ThemePage extends StatefulWidget {
  const ThemePage({super.key});

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  bool _textScaleEnabled = false;

  @override
  void initState() {
    super.initState();
    final current = TextScaleController.instance.textScaleFactor.value;
    _textScaleEnabled =
        (current - TextScaleController.defaultScaleFactor).abs() > 0.001;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('主题'), leading: const BackButton()),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── 主题模式 ──
          const _SectionTitle(icon: Icons.settings_brightness, title: '主题模式'),
          const SizedBox(height: 16),
          _buildModeButtons(context),

          const SizedBox(height: 32),
          // ── 主题色彩 ──
          const _SectionTitle(icon: Icons.palette_outlined, title: '主题色彩'),
          const SizedBox(height: 16),
          _buildPaletteGrid(context),

          const SizedBox(height: 32),
          // ── 纯黑模式 ──
          _buildPureBlack(context),

          const SizedBox(height: 8),
          // ── 文本缩放 ──
          _buildTextScale(context),

          const SizedBox(height: 32),
          // ── 首页卡片文字 ──
          const _SectionTitle(
            icon: Icons.format_color_text_outlined,
            title: '首页卡片文字',
          ),
          const SizedBox(height: 12),
          _buildHomeTextColor(context),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // ── Mode Buttons ──────────────────────────────────────────────────────

  Widget _buildModeButtons(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeModeController.instance.themeMode,
      builder: (context, mode, _) {
        return Row(
          children: [
            Expanded(
              child: _ModeButton(
                icon: Icons.sync,
                label: '自动',
                selected: mode == ThemeMode.system,
                onTap: () =>
                    ThemeModeController.instance.setThemeMode(ThemeMode.system),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModeButton(
                icon: Icons.light_mode,
                label: '浅色',
                selected: mode == ThemeMode.light,
                onTap: () =>
                    ThemeModeController.instance.setThemeMode(ThemeMode.light),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModeButton(
                icon: Icons.dark_mode,
                label: '深色',
                selected: mode == ThemeMode.dark,
                onTap: () =>
                    ThemeModeController.instance.setThemeMode(ThemeMode.dark),
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Palette Grid ──────────────────────────────────────────────────────

  Widget _buildPaletteGrid(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppThemeController.instance.presetSeedIndex,
      builder: (context, selectedIndex, _) {
        return ValueListenableBuilder<AppThemeSeedMode>(
          valueListenable: AppThemeController.instance.seedMode,
          builder: (context, seedMode, _) {
            final isSelected = seedMode == AppThemeSeedMode.preset;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: AppThemeController.presetSeedColors.length + 1,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.0,
              ),
              itemBuilder: (context, index) {
                if (index == AppThemeController.presetSeedColors.length) {
                  return _AddPaletteButton(
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('自定义颜色将在后续版本支持')),
                      );
                    },
                  );
                }
                final seed = AppThemeController.presetSeedColors[index];
                final palette = _paletteFromSeed(seed);
                final selected = isSelected && selectedIndex == index;
                return _PaletteCard(
                  palette: palette,
                  selected: selected,
                  onTap: () async {
                    await AppThemeController.instance.setSeedMode(
                      AppThemeSeedMode.preset,
                    );
                    await AppThemeController.instance.setPresetSeedIndex(index);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// Generate a preview palette from a seed color.
  static _PreviewPalette _paletteFromSeed(Color seed) {
    final cs = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return _PreviewPalette(
      primary: seed,
      secondary: cs.secondary,
      tertiary: cs.tertiary,
      surface: cs.surface,
    );
  }

  // ── Pure Black ────────────────────────────────────────────────────────

  Widget _buildPureBlack(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppThemeController.instance.pureBlackMode,
      builder: (context, enabled, _) {
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.contrast),
          title: const Text('纯黑模式'),
          subtitle: const Text('深色主题使用纯黑背景，适合 OLED 屏幕省电'),
          value: enabled,
          onChanged: AppThemeController.instance.setPureBlackMode,
        );
      },
    );
  }

  // ── Text Scale ────────────────────────────────────────────────────────

  Widget _buildTextScale(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: TextScaleController.instance.textScaleFactor,
      builder: (context, scaleFactor, _) {
        return Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.text_fields),
              title: const Text('文本缩放'),
              subtitle: Text(
                _textScaleEnabled
                    ? '${_formatScale(scaleFactor)} · 默认 ${_formatScale(TextScaleController.defaultScaleFactor)}'
                    : '当前使用默认缩放 ${_formatScale(TextScaleController.defaultScaleFactor)}',
              ),
              value: _textScaleEnabled,
              onChanged: (value) {
                setState(() => _textScaleEnabled = value);
                if (!value) {
                  TextScaleController.instance.setTextScaleFactor(
                    TextScaleController.defaultScaleFactor,
                  );
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
                onChanged: TextScaleController.instance.setTextScaleFactor,
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
                      onPressed: () {
                        TextScaleController.instance.setTextScaleFactor(
                          TextScaleController.defaultScaleFactor,
                        );
                      },
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
      },
    );
  }

  // ── Home Text Color ───────────────────────────────────────────────────

  Widget _buildHomeTextColor(BuildContext context) {
    return ValueListenableBuilder<HomeTextColorMode>(
      valueListenable: AppThemeController.instance.homeTextColorMode,
      builder: (context, mode, _) {
        return SegmentedButton<HomeTextColorMode>(
          segments: HomeTextColorMode.values
              .map((m) => ButtonSegment(value: m, label: Text(m.label)))
              .toList(),
          selected: {mode},
          onSelectionChanged: (selection) {
            AppThemeController.instance.setHomeTextColorMode(selection.first);
          },
          showSelectedIcon: false,
        );
      },
    );
  }

  String _formatScale(double value) => '${(value * 100).round()}%';
}

// ── Preview Palette Model ────────────────────────────────────────────────

class _PreviewPalette {
  final Color primary;
  final Color secondary;
  final Color tertiary;
  final Color surface;

  const _PreviewPalette({
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.surface,
  });
}

// ── Section Title ────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionTitle({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 20,
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
          borderRadius: BorderRadius.circular(18),
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
  final _PreviewPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteCard({
    required this.palette,
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
          borderRadius: BorderRadius.circular(18),
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
                      ColoredBox(color: palette.primary),
                      ColoredBox(color: palette.tertiary),
                      ColoredBox(color: palette.secondary),
                      ColoredBox(
                        color: palette.primary.withValues(alpha: 0.45),
                      ),
                    ],
                  ),
                  if (selected)
                    Icon(Icons.check, size: 20, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Add Palette Button ───────────────────────────────────────────────────

class _AddPaletteButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddPaletteButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Center(
          child: Icon(Icons.add, color: colors.onSurfaceVariant, size: 28),
        ),
      ),
    );
  }
}
