import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_preferences_controller.dart';
import '../../../core/theme/app_typography.dart';

/// 主题模式三选一缩略图画框（跟随系统 / 浅色 / 深色）。
class ThemeModeThumbnails extends StatelessWidget {
  const ThemeModeThumbnails({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final AppThemePreference selected;
  final ValueChanged<AppThemePreference> onChanged;

  static const _items = <({AppThemePreference mode, String label})>[
    (mode: AppThemePreference.system, label: '跟随系统'),
    (mode: AppThemePreference.light, label: '浅色'),
    (mode: AppThemePreference.dark, label: '深色'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _items.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _ModeThumbnailTile(
              mode: _items[i].mode,
              label: _items[i].label,
              selected: selected == _items[i].mode,
              onTap: () => onChanged(_items[i].mode),
            ),
          ),
        ],
      ],
    );
  }
}

class _ModeThumbnailTile extends StatelessWidget {
  const _ModeThumbnailTile({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final AppThemePreference mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: AppRadius.cardBorder,
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: duration,
                curve: AppMotion.standard,
                width: double.infinity,
                height: 74,
                decoration: BoxDecoration(
                  borderRadius: AppRadius.cardBorder,
                  border: Border.all(
                    color: selected ? cs.primary : cs.outlineVariant,
                    width: 1.5,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: cs.primary.withValues(alpha: 0.22),
                            blurRadius: 0,
                            spreadRadius: 3,
                          ),
                        ]
                      : const [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.card - 1.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildPreview(),
                      if (selected)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: cs.primary,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.check,
                              size: 10,
                              color: cs.onPrimary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.tag.copyWith(
                  color: selected ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return switch (mode) {
      AppThemePreference.light => const _MiniUiMockup(dark: false),
      AppThemePreference.dark => const _MiniUiMockup(dark: true),
      AppThemePreference.system => const Stack(
        fit: StackFit.expand,
        children: [
          _MiniUiMockup(dark: false),
          ClipPath(
            clipper: _DiagonalSplitClipper(),
            child: _MiniUiMockup(dark: true),
          ),
        ],
      ),
    };
  }
}

class _MiniUiMockup extends StatelessWidget {
  const _MiniUiMockup({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final bg = dark ? const Color(0xFF15181C) : const Color(0xFFFFFFFF);
    final header = dark ? const Color(0xFF3A3F47) : const Color(0xFFC9CCD2);
    final bar = dark ? const Color(0xFF2B3036) : const Color(0xFFE4E6EA);
    final leftCol = dark ? const Color(0xFF22262B) : const Color(0xFFECEEF2);
    final rightCol = dark ? const Color(0xFF2B3036) : const Color(0xFFE4E6EA);

    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MiniLine(widthFactor: 0.34, color: header),
            const SizedBox(height: 3),
            _MiniLine(widthFactor: 0.70, color: bar),
            const SizedBox(height: 3),
            _MiniLine(widthFactor: 0.55, color: bar),
            const SizedBox(height: 3),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: leftCol,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: rightCol,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniLine extends StatelessWidget {
  const _MiniLine({required this.widthFactor, required this.color});

  final double widthFactor;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 跟随系统缩略图的右半暗面斜切裁切路径（顶边 52% → 底边 34%）。
class _DiagonalSplitClipper extends CustomClipper<Path> {
  const _DiagonalSplitClipper();

  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(size.width * 0.52, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width * 0.34, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant _DiagonalSplitClipper oldClipper) => false;
}
