import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_typography.dart';

import '../grades_score_palette.dart';

/// 成绩分布：一条 8 高圆角堆叠条（段间 2px 缝）+ 图例「优 3 / 良 4 …」。
///
/// 数量为 0 的分段在条与图例中都省略；颜色全部来自 [gradeBandColor]。
class GradesDistributionBar extends StatelessWidget {
  const GradesDistributionBar({super.key, required this.bandCounts});

  final Map<GradeBand, int> bandCounts;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = [
      for (final band in GradeBand.values)
        if ((bandCounts[band] ?? 0) > 0) (band, bandCounts[band]!),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              // 无子节点的 ColoredBox 需要 tight 高度，否则塌成 0 高。
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, (band, count)) in entries.indexed) ...[
                  if (index > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: count,
                    child: ColoredBox(
                      key: ValueKey('grades_band_${band.name}'),
                      color: gradeBandColor(cs, band),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final (band, count) in entries)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: gradeBandColor(cs, band),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${band.label} $count',
                    style: context.appText.meta.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
