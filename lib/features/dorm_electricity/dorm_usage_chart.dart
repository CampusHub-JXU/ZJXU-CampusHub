import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_status_tag.dart';
import '../../shared/widgets/app_tile_surface.dart';
import '../../shared/widgets/plain_list.dart';
import 'dorm_usage_history.dart';

enum _UsageRange {
  day24h('24小时(W)'),
  days7('近7日(度)'),
  days30('近30日(度)');

  const _UsageRange(this.label);
  final String label;
}

class _ChartSample {
  const _ChartSample({
    required this.xFraction,
    required this.value,
    required this.label,
    required this.detail,
    required this.connectedToPrevious,
  });

  final double xFraction;
  final double value;
  final String label;
  final String detail;
  final bool connectedToPrevious;
}

String _clock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _shortDate(DateTime value) => '${value.month}/${value.day}';

class DormUsageChart extends StatefulWidget {
  const DormUsageChart({
    super.key,
    required this.points,
    this.remainingKwh,
    this.currentIntervalValid = true,
    required this.refreshFailed,
    this.backgroundAvailable = false,
    this.backgroundEnabled = false,
    this.onBackgroundChanged,
  });

  final List<DormUsagePoint> points;
  final double? remainingKwh;
  final bool currentIntervalValid;
  final bool refreshFailed;
  final bool backgroundAvailable;
  final bool backgroundEnabled;
  final ValueChanged<bool>? onBackgroundChanged;

  @override
  State<DormUsageChart> createState() => _DormUsageChartState();
}

class _DormUsageChartState extends State<DormUsageChart> {
  _UsageRange _range = _UsageRange.day24h;
  int? _selectedIndex;

  void _selectRange(_UsageRange next) {
    if (_range == next) return;
    setState(() {
      _range = next;
      _selectedIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final recentStart = now.subtract(const Duration(hours: 24));
    final recent = widget.points
        .where((p) => p.endedAt.isAfter(recentStart) && !p.endedAt.isAfter(now))
        .toList();

    final dayTotal = DormUsageHistory.total(widget.points, today, now);
    final weekStart = DateTime(now.year, now.month, now.day - 6);
    final monthStart = DateTime(now.year, now.month, now.day - 29);
    final week = DormUsageHistory.total(widget.points, weekStart, now);
    final month = DormUsageHistory.total(widget.points, monthStart, now);
    final last24 = DormUsageHistory.total(widget.points, recentStart, now);

    final remaining = widget.remainingKwh;
    final estimatedDays =
        remaining != null &&
            remaining.isFinite &&
            remaining >= 0 &&
            last24.coverage >= const Duration(hours: 18) &&
            last24.kwh > 0 &&
            widget.points.isNotEmpty &&
            !now.difference(widget.points.last.endedAt).isNegative &&
            now.difference(widget.points.last.endedAt) <=
                DormUsageHistory.maximumInterval &&
            !widget.refreshFailed &&
            widget.currentIntervalValid
        ? remaining / (last24.kwh * 24 / (last24.coverage.inSeconds / 3600))
        : null;

    final latest = widget.points.isEmpty ? null : widget.points.last;
    final age = latest == null ? null : now.difference(latest.endedAt);
    final stale =
        age != null &&
        (age.isNegative || age > DormUsageHistory.maximumInterval);
    final current =
        stale || widget.refreshFailed || !widget.currentIntervalValid
        ? null
        : latest;

    final (samples, xLabels, rangeCoverage) = _buildChartSeries(
      now,
      today,
      recentStart,
      recent,
    );

    final activeIndex =
        _selectedIndex != null && _selectedIndex! < samples.length
        ? _selectedIndex
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Expanded(child: PlainSectionHeader('用电趋势（本地采样）')),
              if (rangeCoverage != null && rangeCoverage > 0) ...[
                const SizedBox(width: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '覆盖 $rangeCoverage%',
                    maxLines: 1,
                    style: text.meta.copyWith(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.78),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        AppTileSurface(
          blurred: false,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RangeSegmentedControl(selected: _range, onChanged: _selectRange),
              const SizedBox(height: AppSpacing.lg),
              _buildHeadline(
                context,
                cs: cs,
                text: text,
                current: current,
                latest: latest,
                stale: stale,
                estimatedDays: estimatedDays,
                dayTotal: dayTotal,
                weekTotal: week,
                monthTotal: month,
              ),
              const SizedBox(height: AppSpacing.md),
              if (samples.isEmpty)
                _EmptyChartNotice(
                  message: _range == _UsageRange.day24h
                      ? '需两次成功查询，间隔 10 分钟～3 小时'
                      : '暂无每日采样数据',
                )
              else
                _InteractiveLineChart(
                  samples: samples,
                  selectedIndex: activeIndex,
                  xLabels: xLabels,
                  unit: _range == _UsageRange.day24h ? 'W' : '度',
                  onSelect: (idx) => setState(() => _selectedIndex = idx),
                ),
            ],
          ),
        ),
        if (widget.backgroundAvailable) ...[
          const SizedBox(height: AppSpacing.lg),
          PlainListGroup(
            children: [
              PlainSwitchRow(
                title: '后台用电监测',
                subtitle: '约每 1 小时自动采集一次',
                value: widget.backgroundEnabled,
                enabled: widget.onBackgroundChanged != null,
                onChanged: widget.onBackgroundChanged ?? (_) {},
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildHeadline(
    BuildContext context, {
    required ColorScheme cs,
    required AppTypography text,
    required DormUsagePoint? current,
    required DormUsagePoint? latest,
    required bool stale,
    required double? estimatedDays,
    required DormUsageTotal dayTotal,
    required DormUsageTotal weekTotal,
    required DormUsageTotal monthTotal,
  }) {
    if (_range == _UsageRange.day24h) {
      final numPart = current == null ? '--' : current.watts.toStringAsFixed(0);
      final dayStr = dayTotal.coverage == Duration.zero
          ? '--'
          : '${dayTotal.kwh.toStringAsFixed(2)}°';
      final weekStr = weekTotal.coverage == Duration.zero
          ? '--'
          : '${weekTotal.kwh.toStringAsFixed(1)}°';
      final valueColor = current == null ? cs.outlineVariant : cs.onSurface;
      final unitColor = current == null
          ? cs.outlineVariant
          : cs.onSurfaceVariant;
      final valueStyle = text.meta.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: numPart,
                          style: text.numValue.copyWith(color: valueColor),
                        ),
                        TextSpan(
                          text: ' W',
                          style: text.numUnit.copyWith(
                            fontWeight: FontWeight.w600,
                            color: unitColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (estimatedDays != null)
                    AppStatusTag(
                      '约可用 ${estimatedDays.toStringAsFixed(1)} 天',
                      tone: estimatedDays < 2
                          ? AppStatusTone.attention
                          : AppStatusTone.positive,
                    ),
                ],
              ),
              Text.rich(
                TextSpan(
                  style: text.meta,
                  children: [
                    const TextSpan(text: '今日 '),
                    TextSpan(text: dayStr, style: valueStyle),
                    const TextSpan(text: ' · 7日 '),
                    TextSpan(text: weekStr, style: valueStyle),
                  ],
                ),
              ),
            ],
          ),
          if (widget.refreshFailed) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('刷新失败，历史记录不代表当前功率', style: text.meta),
          ] else if (!widget.currentIntervalValid &&
              latest != null &&
              !stale) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('等待间隔 10 分钟以上的下次采样', style: text.meta),
          ] else if (current != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              current.watts == 0
                  ? '最近区间未观测到耗电'
                  : '${(current.watts / 1000).toStringAsFixed(3)} 度/小时',
              style: text.meta.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      );
    }

    final total = _range == _UsageRange.days7 ? weekTotal : monthTotal;
    final daysCount = _range == _UsageRange.days7 ? 7 : 30;
    final hasData = total.coverage > Duration.zero;
    final avgPerDay = hasData && total.coverage.inMinutes > 0
        ? total.kwh * 24 / (total.coverage.inMinutes / 60)
        : null;
    final valueColor = hasData ? cs.onSurface : cs.outlineVariant;
    final unitColor = hasData ? cs.onSurfaceVariant : cs.outlineVariant;

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: hasData ? total.kwh.toStringAsFixed(2) : '--',
                    style: text.numValue.copyWith(color: valueColor),
                  ),
                  TextSpan(
                    text: ' 度',
                    style: text.numUnit.copyWith(
                      fontWeight: FontWeight.w600,
                      color: unitColor,
                    ),
                  ),
                ],
              ),
            ),
            if (avgPerDay != null)
              AppStatusTag(
                '日均 ${avgPerDay.toStringAsFixed(2)} 度',
                tone: AppStatusTone.neutral,
              ),
          ],
        ),
        Text('近 $daysCount 日累计', style: text.meta),
      ],
    );
  }

  (List<_ChartSample>, List<String>, int?) _buildChartSeries(
    DateTime now,
    DateTime today,
    DateTime recentStart,
    List<DormUsagePoint> recent,
  ) {
    if (_range == _UsageRange.day24h) {
      final totalSpan = now.difference(recentStart).inMicroseconds;
      final cov = DormUsageHistory.total(widget.points, recentStart, now);
      final pct = totalSpan <= 0
          ? null
          : (100 * cov.coverage.inMicroseconds / totalSpan)
                .clamp(0, 100)
                .round();
      final samples = <_ChartSample>[];
      for (var i = 0; i < recent.length; i++) {
        final p = recent[i];
        final frac = totalSpan <= 0
            ? 0.5
            : (p.endedAt.difference(recentStart).inMicroseconds / totalSpan)
                  .clamp(0.0, 1.0);
        final connected = i > 0 && p.startedAt == recent[i - 1].endedAt;
        samples.add(
          _ChartSample(
            xFraction: frac,
            value: p.watts,
            label: _clock(p.endedAt),
            detail: '${_clock(p.endedAt)} · ${p.watts.toStringAsFixed(0)} W',
            connectedToPrevious: connected,
          ),
        );
      }
      final labels = [
        '昨日 ${_clock(recentStart)}',
        _clock(recentStart.add(const Duration(hours: 8))),
        _clock(recentStart.add(const Duration(hours: 16))),
        '现在',
      ];
      return (samples, labels, pct);
    }

    final daysCount = _range == _UsageRange.days7 ? 7 : 30;
    final startDay = DateTime(
      today.year,
      today.month,
      today.day - (daysCount - 1),
    );
    final totalSpan = now.difference(startDay).inMicroseconds;
    final cov = DormUsageHistory.total(widget.points, startDay, now);
    final pct = totalSpan <= 0
        ? null
        : (100 * cov.coverage.inMicroseconds / totalSpan).clamp(0, 100).round();

    final samples = <_ChartSample>[];
    var previousHadData = false;
    for (var i = 0; i < daysCount; i++) {
      final day = DateTime(startDay.year, startDay.month, startDay.day + i);
      final end = day == today
          ? now
          : DateTime(day.year, day.month, day.day + 1);
      final total = DormUsageHistory.total(widget.points, day, end);
      if (total.coverage == Duration.zero) {
        previousHadData = false;
        continue;
      }
      final frac = daysCount <= 1 ? 0.5 : i / (daysCount - 1);
      final dayLabel = day == today ? '今天' : _shortDate(day);
      samples.add(
        _ChartSample(
          xFraction: frac,
          value: total.kwh,
          label: dayLabel,
          detail: '$dayLabel · ${total.kwh.toStringAsFixed(2)} 度',
          connectedToPrevious: previousHadData,
        ),
      );
      previousHadData = true;
    }

    final labels = _range == _UsageRange.days7
        ? [
            _shortDate(startDay),
            _shortDate(
              DateTime(startDay.year, startDay.month, startDay.day + 2),
            ),
            _shortDate(
              DateTime(startDay.year, startDay.month, startDay.day + 4),
            ),
            '今天',
          ]
        : [
            _shortDate(startDay),
            _shortDate(
              DateTime(startDay.year, startDay.month, startDay.day + 10),
            ),
            _shortDate(
              DateTime(startDay.year, startDay.month, startDay.day + 20),
            ),
            '今天',
          ];
    return (samples, labels, pct);
  }
}

class _EmptyChartNotice extends StatelessWidget {
  const _EmptyChartNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(
          alpha: isDark ? 0.25 : 0.38,
        ),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.show_chart_rounded,
              size: 20,
              color: cs.onSurfaceVariant.withValues(alpha: 0.65),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.appText.meta,
            ),
          ],
        ),
      ),
    );
  }
}

class _RangeSegmentedControl extends StatelessWidget {
  const _RangeSegmentedControl({
    required this.selected,
    required this.onChanged,
  });

  final _UsageRange selected;
  final ValueChanged<_UsageRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reducedMotion = AppMotion.reduced(context);
    final activeColor = isDark
        ? cs.surfaceContainerHigh
        : cs.surfaceContainerLowest;
    final trackColor = cs.surfaceContainerHighest.withValues(
      alpha: isDark ? 0.55 : 0.72,
    );

    return AppTextScaleGuard.chrome(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(AppRadius.segment),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              for (final range in _UsageRange.values)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: selected == range,
                    label: range.label,
                    child: GestureDetector(
                      onTap: () => onChanged(range),
                      behavior: HitTestBehavior.opaque,
                      child: AnimatedContainer(
                        duration: reducedMotion
                            ? Duration.zero
                            : AppMotion.quick,
                        curve: AppMotion.standard,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: selected == range
                              ? activeColor
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(
                            AppRadius.segment - 3,
                          ),
                          boxShadow: selected == range && !isDark
                              ? [
                                  BoxShadow(
                                    color: cs.shadow.withValues(alpha: 0.06),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ]
                              : null,
                        ),
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              range.label,
                              maxLines: 1,
                              style: AppChromeType.segment.copyWith(
                                color: selected == range
                                    ? cs.onSurface
                                    : cs.onSurfaceVariant,
                                fontWeight: selected == range
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InteractiveLineChart extends StatefulWidget {
  const _InteractiveLineChart({
    required this.samples,
    required this.selectedIndex,
    required this.xLabels,
    required this.unit,
    required this.onSelect,
  });

  final List<_ChartSample> samples;
  final int? selectedIndex;
  final List<String> xLabels;
  final String unit;
  final ValueChanged<int?> onSelect;

  @override
  State<_InteractiveLineChart> createState() => _InteractiveLineChartState();
}

class _InteractiveLineChartState extends State<_InteractiveLineChart> {
  static const double _plotHorizontalPad = 8.0;
  bool _tappedAlreadySelected = false;

  int? _nearestIndex(Offset localPos, double width) {
    if (widget.samples.isEmpty) return null;
    final plotWidth = width - _plotHorizontalPad * 2;
    if (plotWidth <= 0) return null;
    final targetFrac = ((localPos.dx - _plotHorizontalPad) / plotWidth).clamp(
      0.0,
      1.0,
    );
    var bestIdx = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < widget.samples.length; i++) {
      final d = (widget.samples[i].xFraction - targetFrac).abs();
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  void _selectAt(Offset localPos, double width) {
    final idx = _nearestIndex(localPos, width);
    if (idx != null) {
      widget.onSelect(idx);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardSurface = isDark
        ? cs.surfaceContainerLow
        : cs.surfaceContainerLowest;
    final selected =
        widget.selectedIndex != null &&
            widget.selectedIndex! < widget.samples.length
        ? widget.samples[widget.selectedIndex!]
        : null;

    return Semantics(
      image: true,
      label: '用电趋势折线图，${widget.samples.length} 个采样点',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final plotWidth = math.max(0.0, width - _plotHorizontalPad * 2);
          final selectedX = selected == null
              ? 0.0
              : _plotHorizontalPad + plotWidth * selected.xFraction;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final idx = _nearestIndex(d.localPosition, width);
              _tappedAlreadySelected =
                  idx != null && idx == widget.selectedIndex;
              if (idx != null && idx != widget.selectedIndex) {
                widget.onSelect(idx);
              }
            },
            onTapUp: (_) {
              if (_tappedAlreadySelected) {
                _tappedAlreadySelected = false;
                widget.onSelect(null);
              }
            },
            onTapCancel: () => _tappedAlreadySelected = false,
            onHorizontalDragStart: (d) {
              _tappedAlreadySelected = false;
              _selectAt(d.localPosition, width);
            },
            onHorizontalDragUpdate: (d) {
              _tappedAlreadySelected = false;
              _selectAt(d.localPosition, width);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 26,
                  child: selected == null
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            '点按或滑动曲线查看读数',
                            style: context.appText.tag.copyWith(
                              fontWeight: FontWeight.w400,
                              color: cs.onSurfaceVariant.withValues(
                                alpha: 0.72,
                              ),
                            ),
                          ),
                        )
                      : CustomSingleChildLayout(
                          delegate: _TooltipLayoutDelegate(anchorX: selectedX),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: cs.inverseSurface,
                              borderRadius: BorderRadius.circular(
                                AppRadius.tag,
                              ),
                              boxShadow: isDark
                                  ? null
                                  : [
                                      BoxShadow(
                                        color: cs.shadow.withValues(
                                          alpha: 0.14,
                                        ),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              child: Text(
                                selected.detail,
                                maxLines: 1,
                                style: context.appText.tag.copyWith(
                                  color: cs.onInverseSurface,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 126,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _AreaLinePainter(
                      samples: widget.samples,
                      selectedIndex: widget.selectedIndex,
                      colors: cs,
                      cardSurface: cardSurface,
                      isDark: isDark,
                      unit: widget.unit,
                      horizontalPad: _plotHorizontalPad,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final label in widget.xLabels)
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.appText.tag.copyWith(
                              fontWeight: FontWeight.w400,
                              color: cs.onSurfaceVariant.withValues(
                                alpha: 0.78,
                              ),
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TooltipLayoutDelegate extends SingleChildLayoutDelegate {
  _TooltipLayoutDelegate({required this.anchorX});

  final double anchorX;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxDx = math.max(0.0, size.width - childSize.width);
    final dx = (anchorX - childSize.width / 2).clamp(0.0, maxDx);
    final dy = ((size.height - childSize.height) / 2).clamp(0.0, size.height);
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(covariant _TooltipLayoutDelegate oldDelegate) =>
      oldDelegate.anchorX != anchorX;
}

class _AreaLinePainter extends CustomPainter {
  _AreaLinePainter({
    required this.samples,
    required this.selectedIndex,
    required this.colors,
    required this.cardSurface,
    required this.isDark,
    required this.unit,
    required this.horizontalPad,
  });

  final List<_ChartSample> samples;
  final int? selectedIndex;
  final ColorScheme colors;
  final Color cardSurface;
  final bool isDark;
  final String unit;
  final double horizontalPad;

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    double dash = 3.5,
    double gap = 3.5,
  }) {
    final delta = end - start;
    final distance = delta.distance;
    if (distance <= 0) return;
    final unitVec = delta / distance;
    var drawn = 0.0;
    while (drawn < distance) {
      final next = math.min(drawn + dash, distance);
      canvas.drawLine(start + unitVec * drawn, start + unitVec * next, paint);
      drawn = next + gap;
    }
  }

  bool _isIsolatedPoint(int index) {
    final prevConnected = index > 0 && samples[index].connectedToPrevious;
    final nextConnected =
        index + 1 < samples.length && samples[index + 1].connectedToPrevious;
    return !prevConnected && !nextConnected;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || size.width < 80 || size.height < 48) return;
    final plot = Rect.fromLTRB(
      horizontalPad,
      10,
      size.width - horizontalPad,
      size.height - 6,
    );
    final peak = samples.map((s) => s.value).reduce(math.max);
    final minScale = unit == 'W' ? 100.0 : 1.0;
    final scale = math.max(minScale, peak * 1.15);

    // 2 条柔和水平参考虚线 + 1 条底基准线
    final dashedGrid = Paint()
      ..color = colors.outlineVariant.withValues(alpha: isDark ? 0.34 : 0.52)
      ..strokeWidth = 0.9;
    final baseGrid = Paint()
      ..color = colors.outlineVariant.withValues(alpha: isDark ? 0.42 : 0.65)
      ..strokeWidth = 0.9;
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      baseGrid,
    );
    for (final ratio in const [1 / 3, 2 / 3]) {
      final y = plot.bottom - plot.height * ratio;
      _drawDashedLine(
        canvas,
        Offset(plot.left, y),
        Offset(plot.right, y),
        dashedGrid,
        dash: 3.0,
        gap: 3.5,
      );
    }

    final offsets = samples.map((s) {
      return Offset(
        plot.left + plot.width * s.xFraction,
        plot.bottom - plot.height * (s.value / scale).clamp(0.0, 1.0),
      );
    }).toList();

    // 连续实线段填充渐变面积（采样缺口处断开，不填充误导面积）
    final areaPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          colors.primary.withValues(alpha: isDark ? 0.28 : 0.20),
          colors.primary.withValues(alpha: isDark ? 0.02 : 0.01),
        ],
      ).createShader(plot)
      ..style = PaintingStyle.fill;

    var segStart = 0;
    while (segStart < offsets.length) {
      var segEnd = segStart;
      while (segEnd + 1 < offsets.length &&
          samples[segEnd + 1].connectedToPrevious) {
        segEnd++;
      }
      if (segEnd > segStart) {
        final area = Path()..moveTo(offsets[segStart].dx, plot.bottom);
        for (var i = segStart; i <= segEnd; i++) {
          area.lineTo(offsets[i].dx, offsets[i].dy);
        }
        area
          ..lineTo(offsets[segEnd].dx, plot.bottom)
          ..close();
        canvas.drawPath(area, areaPaint);
      }
      segStart = segEnd + 1;
    }

    // 仅连接连续区间；采样缺口（connectedToPrevious == false）断开绘制
    final solidLine = Paint()
      ..color = colors.primary
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (var i = 1; i < offsets.length; i++) {
      if (samples[i].connectedToPrevious) {
        canvas.drawLine(offsets[i - 1], offsets[i], solidLine);
      }
    }

    // 数据点：短序列与孤立采样点显示小圆点，长序列保持线条干净
    final dotPaint = Paint()..color = colors.primary;
    final showAllDots = offsets.length <= 32;
    for (var i = 0; i < offsets.length; i++) {
      if (i == selectedIndex) continue;
      if (showAllDots || _isIsolatedPoint(i)) {
        canvas.drawCircle(offsets[i], 2.6, dotPaint);
      }
    }

    // 选中态：垂直指示虚线 + 外圈光晕 + 实心点
    if (selectedIndex != null && selectedIndex! < offsets.length) {
      final pt = offsets[selectedIndex!];
      final guide = Paint()
        ..color = colors.primary.withValues(alpha: isDark ? 0.48 : 0.36)
        ..strokeWidth = 1.1;
      _drawDashedLine(
        canvas,
        Offset(pt.dx, 0),
        Offset(pt.dx, plot.bottom),
        guide,
      );
      canvas.drawCircle(
        pt,
        9.5,
        Paint()..color = colors.primary.withValues(alpha: isDark ? 0.26 : 0.16),
      );
      canvas.drawCircle(pt, 5.5, Paint()..color = cardSurface);
      canvas.drawCircle(pt, 3.8, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AreaLinePainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.colors != colors ||
      oldDelegate.cardSurface != cardSurface ||
      oldDelegate.isDark != isDark ||
      oldDelegate.unit != unit ||
      oldDelegate.horizontalPad != horizontalPad;
}
