import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_preferences_controller.dart';
import '../../../core/theme/app_theme_palette.dart';
import '../../../shared/widgets/plain_list.dart';

/// 主题色彩 9 行紧凑列表（8 个预设色 + 1 个自定义色入口）。
class ThemeColorList extends StatelessWidget {
  const ThemeColorList({
    super.key,
    required this.colorSource,
    required this.paletteIndex,
    required this.customSeedColor,
    required this.onSelectPreset,
    required this.onTapCustom,
  });

  final AppColorPreference colorSource;
  final int paletteIndex;
  final Color customSeedColor;
  final ValueChanged<int> onSelectPreset;
  final VoidCallback onTapCustom;

  static final List<_PresetSwatchEntry> _presetEntries = List.unmodifiable(
    themePalettes.map((palette) {
      final pair = _deriveDualPrimary(palette.primary);
      return _PresetSwatchEntry(
        label: palette.label,
        light: pair.light,
        dark: pair.dark,
        subtitle: '${_formatHex(pair.light)} → ${_formatHex(pair.dark)}',
      );
    }),
  );

  @override
  Widget build(BuildContext context) {
    final customPair = _deriveDualPrimary(customSeedColor);
    final isCustomSelected = colorSource == AppColorPreference.custom;

    return PlainListGroup(
      children: [
        for (var i = 0; i < _presetEntries.length; i++)
          _buildPresetRow(
            entry: _presetEntries[i],
            selected:
                colorSource == AppColorPreference.preset && paletteIndex == i,
            onTap: () => onSelectPreset(i),
          ),
        Semantics(
          selected: isCustomSelected,
          child: PlainListRow(
            key: const ValueKey('custom-theme-color-button'),
            leading: _DualColorDot(
              lightColor: customPair.light,
              darkColor: customPair.dark,
              selected: isCustomSelected,
              isCustom: true,
            ),
            title: '自定义',
            subtitle:
                '${_formatHex(customPair.light)} → ${_formatHex(customPair.dark)}',
            trailing: _SelectionRadio(selected: isCustomSelected),
            showChevron: false,
            onTap: onTapCustom,
          ),
        ),
      ],
    );
  }

  Widget _buildPresetRow({
    required _PresetSwatchEntry entry,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Semantics(
      selected: selected,
      child: PlainListRow(
        leading: _DualColorDot(
          lightColor: entry.light,
          darkColor: entry.dark,
          selected: selected,
          isCustom: false,
        ),
        title: entry.label,
        subtitle: entry.subtitle,
        trailing: _SelectionRadio(selected: selected),
        showChevron: false,
        onTap: onTap,
      ),
    );
  }
}

class _PresetSwatchEntry {
  const _PresetSwatchEntry({
    required this.label,
    required this.light,
    required this.dark,
    required this.subtitle,
  });

  final String label;
  final Color light;
  final Color dark;
  final String subtitle;
}

({Color light, Color dark}) _deriveDualPrimary(Color seed) {
  final light = ColorScheme.fromSeed(seedColor: seed).primary;
  final dark = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.dark,
  ).primary;
  return (light: light, dark: dark);
}

String _formatHex(Color color) {
  final rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

class _DualColorDot extends StatelessWidget {
  const _DualColorDot({
    required this.lightColor,
    required this.darkColor,
    required this.selected,
    required this.isCustom,
  });

  final Color lightColor;
  final Color darkColor;
  final bool selected;
  final bool isCustom;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;

    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.standard,
      width: 34,
      height: 34,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? cs.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: SizedBox(
        width: 26,
        height: 26,
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: lightColor),
              ClipPath(
                clipper: const _RightHalfClipper(),
                child: ColoredBox(color: darkColor),
              ),
              if (isCustom || selected)
                Center(
                  child: Icon(
                    isCustom ? Icons.edit_outlined : Icons.check,
                    size: isCustom ? 13 : 14,
                    color: Colors.white,
                    shadows: const [
                      Shadow(color: Color(0x59000000), blurRadius: 3),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RightHalfClipper extends CustomClipper<Path> {
  const _RightHalfClipper();

  @override
  Path getClip(Size size) {
    return Path()
      ..addRect(Rect.fromLTRB(size.width * 0.5, 0, size.width, size.height));
  }

  @override
  bool shouldReclip(covariant _RightHalfClipper oldClipper) => false;
}

class _SelectionRadio extends StatelessWidget {
  const _SelectionRadio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;

    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.standard,
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? cs.primary : cs.outlineVariant,
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: AnimatedScale(
        scale: selected ? 1 : 0,
        duration: duration,
        curve: AppMotion.standard,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: cs.primary),
        ),
      ),
    );
  }
}
