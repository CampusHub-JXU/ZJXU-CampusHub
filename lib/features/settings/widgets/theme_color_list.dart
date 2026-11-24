import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_preferences_controller.dart';
import '../../../core/theme/app_theme_palette.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/plain_list.dart';

/// 主题色彩紧凑矩阵（8 个预设校色/莫奈色珠 + 1 个自定义取色入口）。
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

  static const int _columns = 5;

  static final List<_PresetSwatchEntry> _presetEntries = List.unmodifiable(
    themePalettes.map((palette) {
      final monetPrimary = ColorScheme.fromSeed(
        seedColor: palette.primary,
        brightness: Brightness.dark,
      ).primary;
      return _PresetSwatchEntry(
        label: palette.label,
        seed: palette.primary,
        monetAccent: monetPrimary,
      );
    }),
  );

  static final List<Color> _spectrumColors = List.unmodifiable([
    themePalettes[0].primary,
    themePalettes[5].primary,
    themePalettes[6].primary,
    themePalettes[2].primary,
    themePalettes[1].primary,
    themePalettes[3].primary,
    themePalettes[4].primary,
    themePalettes[0].primary,
  ]);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;

    final isCustomSelected = colorSource == AppColorPreference.custom;
    final safeIndex = paletteIndex.clamp(0, _presetEntries.length - 1);
    final activeEntry = _presetEntries[safeIndex];
    final customMonetAccent = ColorScheme.fromSeed(
      seedColor: customSeedColor,
      brightness: Brightness.dark,
    ).primary;

    final activeLabel = isCustomSelected ? '自定义' : activeEntry.label;
    final activeSeed = isCustomSelected ? customSeedColor : activeEntry.seed;
    final activeAccent = isCustomSelected
        ? customMonetAccent
        : activeEntry.monetAccent;
    final activeRingColor = isDark ? activeAccent : activeSeed;

    final beads = <Widget>[
      for (var i = 0; i < _presetEntries.length; i++)
        _PresetColorBead(
          entry: _presetEntries[i],
          selected: !isCustomSelected && safeIndex == i,
          onTap: () => onSelectPreset(i),
        ),
      _CustomColorBead(
        key: const ValueKey('custom-theme-color-button'),
        seedColor: customSeedColor,
        monetAccent: customMonetAccent,
        spectrumColors: _spectrumColors,
        selected: isCustomSelected,
        onTap: onTapCustom,
      ),
    ];

    final rows = <List<Widget>>[];
    for (var start = 0; start < beads.length; start += _columns) {
      final end = (start + _columns).clamp(0, beads.length);
      rows.add(beads.sublist(start, end));
    }

    return PlainListGroup(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AnimatedContainer(
                    duration: duration,
                    curve: AppMotion.standard,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: ShapeDecoration(
                      color: activeRingColor.withValues(
                        alpha: isDark ? 0.18 : 0.10,
                      ),
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MiniDualDot(primary: activeSeed, accent: activeAccent),
                        const SizedBox(width: 6),
                        Text(
                          activeLabel,
                          style: context.appText.group.copyWith(
                            color: cs.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatHex(activeSeed),
                    style: context.appText.meta.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              for (var r = 0; r < rows.length; r++) ...[
                if (r > 0) const SizedBox(height: 10),
                Row(
                  children: [
                    for (var c = 0; c < _columns; c++)
                      Expanded(
                        child: c < rows[r].length
                            ? Center(child: rows[r][c])
                            : const SizedBox(width: 48, height: 48),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PresetSwatchEntry {
  const _PresetSwatchEntry({
    required this.label,
    required this.seed,
    required this.monetAccent,
  });

  final String label;
  final Color seed;
  final Color monetAccent;
}

class _PresetColorBead extends StatelessWidget {
  const _PresetColorBead({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _PresetSwatchEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;
    final ringColor = isDark ? entry.monetAccent : entry.seed;
    final avgLuminance =
        (entry.seed.computeLuminance() + entry.monetAccent.computeLuminance()) *
        0.5;
    final checkColor = avgLuminance > 0.62 ? Colors.black87 : Colors.white;

    return Semantics(
      button: true,
      selected: selected,
      label: entry.label,
      child: Tooltip(
        message: entry.label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: duration,
                curve: AppMotion.standard,
                width: 42,
                height: 42,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? ringColor : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: _DualToneOrb(
                  primary: entry.seed,
                  accent: entry.monetAccent,
                  outlineColor: cs.onSurface.withValues(
                    alpha: isDark ? 0.16 : 0.10,
                  ),
                  child: AnimatedScale(
                    scale: selected ? 1 : 0,
                    duration: duration,
                    curve: AppMotion.standard,
                    child: Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: checkColor,
                      shadows: avgLuminance > 0.62
                          ? null
                          : [
                              Shadow(
                                color: cs.shadow.withValues(alpha: 0.45),
                                blurRadius: 3,
                              ),
                            ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomColorBead extends StatelessWidget {
  const _CustomColorBead({
    super.key,
    required this.seedColor,
    required this.monetAccent,
    required this.spectrumColors,
    required this.selected,
    required this.onTap,
  });

  final Color seedColor;
  final Color monetAccent;
  final List<Color> spectrumColors;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;
    final ringColor = isDark ? monetAccent : seedColor;
    final avgLuminance =
        (seedColor.computeLuminance() + monetAccent.computeLuminance()) * 0.5;
    final selectedIconColor = avgLuminance > 0.62
        ? Colors.black87
        : Colors.white;

    return Semantics(
      button: true,
      selected: selected,
      label: '自定义',
      child: Tooltip(
        message: '自定义',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: duration,
                curve: AppMotion.standard,
                width: 42,
                height: 42,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? ringColor : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: selected
                    ? _DualToneOrb(
                        primary: seedColor,
                        accent: monetAccent,
                        outlineColor: cs.onSurface.withValues(
                          alpha: isDark ? 0.16 : 0.10,
                        ),
                        child: Icon(
                          Icons.palette_outlined,
                          size: 16,
                          color: selectedIconColor,
                          shadows: avgLuminance > 0.62
                              ? null
                              : [
                                  Shadow(
                                    color: cs.shadow.withValues(alpha: 0.45),
                                    blurRadius: 3,
                                  ),
                                ],
                        ),
                      )
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(colors: spectrumColors),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(2.5),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: cs.surfaceContainerHighest,
                            ),
                            child: Center(
                              child: Icon(
                                Icons.palette_outlined,
                                size: 15,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DualToneOrb extends StatelessWidget {
  const _DualToneOrb({
    required this.primary,
    required this.accent,
    required this.outlineColor,
    this.child,
  });

  final Color primary;
  final Color accent;
  final Color outlineColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: outlineColor, width: 0.75),
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: primary),
            ClipPath(
              clipper: const _DiagonalBottomRightClipper(),
              child: ColoredBox(color: accent),
            ),
            if (child != null) Center(child: child),
          ],
        ),
      ),
    );
  }
}

class _MiniDualDot extends StatelessWidget {
  const _MiniDualDot({required this.primary, required this.accent});

  final Color primary;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 11,
      height: 11,
      child: _DualToneOrb(
        primary: primary,
        accent: accent,
        outlineColor: cs.onSurface.withValues(alpha: 0.14),
      ),
    );
  }
}

class _DiagonalBottomRightClipper extends CustomClipper<Path> {
  const _DiagonalBottomRightClipper();

  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant _DiagonalBottomRightClipper oldClipper) => false;
}

String _formatHex(Color color) {
  final rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
