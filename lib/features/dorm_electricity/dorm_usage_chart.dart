import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'dorm_usage_history.dart';

String _clock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

class DormUsageChart extends StatelessWidget {
  const DormUsageChart({
    super.key,
    required this.points,
    this.remainingKwh,
    this.currentIntervalValid = true,
    required this.monitoring,
    required this.canMonitor,
    required this.refreshFailed,
    required this.onMonitoringChanged,
    this.backgroundAvailable = false,
    this.backgroundEnabled = false,
    this.onBackgroundChanged,
  });

  final List<DormUsagePoint> points;
  final double? remainingKwh;
  final bool currentIntervalValid;
  final bool monitoring;
  final bool canMonitor;
  final bool refreshFailed;
  final ValueChanged<bool> onMonitoringChanged;
  final bool backgroundAvailable;
  final bool backgroundEnabled;
  final ValueChanged<bool>? onBackgroundChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final recentStart = now.subtract(const Duration(hours: 24));
    final recent = points
        .where((p) => p.endedAt.isAfter(recentStart) && !p.endedAt.isAfter(now))
        .toList();
    final dayTotal = DormUsageHistory.total(points, today, now);
    final yesterdayTotal = DormUsageHistory.total(points, yesterday, today);
    final weekStart = DateTime(now.year, now.month, now.day - 6);
    final monthStart = DateTime(now.year, now.month, now.day - 29);
    final week = DormUsageHistory.total(points, weekStart, now);
    final month = DormUsageHistory.total(points, monthStart, now);
    final last24 = DormUsageHistory.total(points, recentStart, now);
    final remaining = remainingKwh;
    final days =
        remaining != null &&
            remaining.isFinite &&
            remaining >= 0 &&
            last24.coverage >= const Duration(hours: 18) &&
            last24.kwh > 0 &&
            points.isNotEmpty &&
            !now.difference(points.last.endedAt).isNegative &&
            now.difference(points.last.endedAt) <=
                DormUsageHistory.maximumInterval &&
            !refreshFailed &&
            currentIntervalValid
        ? remaining / (last24.kwh * 24 / (last24.coverage.inSeconds / 3600))
        : null;
    final latest = points.isEmpty ? null : points.last;
    final age = latest == null
        ? null
        : DateTime.now().difference(latest.endedAt);
    final stale =
        age != null &&
        (age.isNegative || age > DormUsageHistory.maximumInterval);
    final current = stale || refreshFailed || !currentIntervalValid
        ? null
        : latest;
    final String value = current == null
        ? '-- W'
        : '${current.watts.toStringAsFixed(0)} W';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('智能用电分析', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              value,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: colors.primary,
              ),
            ),
            Text(
              current != null
                  ? (current.watts == 0
                        ? '本区间未观测到电量下降，不代表没有用电'
                        : '${(current.watts / 1000).toStringAsFixed(3)} 度/小时 · 区间平均')
                  : (refreshFailed ? '刷新失败，历史记录不代表当前功率' : '暂无近期有效估算'),
              style: theme.textTheme.bodySmall,
            ),
            if (latest != null)
              Text(
                '最近采样结束：${latest.endedAt.month}月${latest.endedAt.day}日 '
                '${_clock(latest.endedAt)} · ${(latest.duration.inSeconds / 60).toStringAsFixed(1)}分钟区间',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            _summary('今日已观测耗电', dayTotal, today, now),
            _summary('昨日已观测耗电', yesterdayTotal, yesterday, today),
            _summary('近7日已观测耗电', week, weekStart, now),
            _summary('近30日已观测耗电', month, monthStart, now),
            Text(
              '预计可用：${days == null ? '数据不足' : '${days.toStringAsFixed(1)} 天'}',
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              '按近24小时已观测均速外推，至少覆盖18小时；非保证值。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (recent.isEmpty)
              const SizedBox(
                height: 100,
                child: Center(child: Text('需两次成功查询，间隔10～30分钟')),
              )
            else ...[
              Text('近24小时耗电趋势（W）', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              Semantics(
                image: true,
                label:
                    '耗电趋势，${recent.length}个区间，'
                    '最近区间平均${latest!.watts.toStringAsFixed(0)}瓦',
                child: SizedBox(
                  width: double.infinity,
                  height: 164,
                  child: CustomPaint(
                    painter: _UsagePainter(recent, colors, recentStart, now),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('近7日用电（已观测）', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            ..._dailyBars(context, points, today, now),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('前台自动监测'),
              subtitle: const Text('每10分钟尝试查询；退出或切后台暂停'),
              value: monitoring,
              onChanged: canMonitor || monitoring ? onMonitoringChanged : null,
            ),
            if (backgroundAvailable)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('后台用电采集（实验性）'),
                subtitle: const Text('约15分钟调度；系统可能延迟，登录失效时暂停'),
                value: backgroundEnabled,
                onChanged: onBackgroundChanged,
              ),
            Text(
              '按剩余电量差值估算；电表上报延迟、精度和充值均会影响结果。'
              '仅记录成功采样；缺测不计为零。数据本地保留约31天，跨日区间按时长估分。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(
    String label,
    DormUsageTotal total,
    DateTime start,
    DateTime end,
  ) {
    final span = end.difference(start).inMicroseconds;
    final coverage = span <= 0
        ? 0
        : (100 * total.coverage.inMicroseconds / span).clamp(0, 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label：${total.coverage == Duration.zero ? '--' : '${total.kwh.toStringAsFixed(2)} 度'} · 覆盖 $coverage%',
      ),
    );
  }

  List<Widget> _dailyBars(
    BuildContext context,
    List<DormUsagePoint> points,
    DateTime today,
    DateTime now,
  ) {
    final days = List.generate(
      7,
      (i) => DateTime(today.year, today.month, today.day - 6 + i),
    );
    final totals = days
        .map(
          (d) => DormUsageHistory.total(
            points,
            d,
            d == today ? now : DateTime(d.year, d.month, d.day + 1),
          ),
        )
        .toList();
    final max = totals.fold<double>(0, (a, b) => math.max(a, b.kwh));
    return List.generate(7, (i) {
      final d = days[i];
      final t = totals[i];
      final end = d == today ? now : DateTime(d.year, d.month, d.day + 1);
      final span = end.difference(d).inMicroseconds;
      final coverage = span <= 0
          ? 0
          : (100 * t.coverage.inMicroseconds / span).clamp(0, 100).round();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 44, child: Text('${d.month}/${d.day}')),
            Expanded(
              child: t.coverage == Duration.zero
                  ? const Text('无数据')
                  : LinearProgressIndicator(
                      value: max == 0
                          ? 0
                          : (t.kwh / max).clamp(0.0, 1.0).toDouble(),
                      minHeight: 8,
                      semanticsLabel: '已观测耗电 ${t.kwh.toStringAsFixed(2)} 度',
                    ),
            ),
            const SizedBox(width: 8),
            Text(
              t.coverage == Duration.zero
                  ? '—'
                  : '${t.kwh.toStringAsFixed(2)} 度 · $coverage%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    });
  }
}

class _UsagePainter extends CustomPainter {
  _UsagePainter(this.points, this.colors, this.start, this.end);
  final DateTime start;
  final DateTime end;
  final List<DormUsagePoint> points;
  final ColorScheme colors;

  void _label(Canvas canvas, String text, Offset position, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, position);
    painter.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width < 100 || size.height < 60) return;
    final plot = Rect.fromLTRB(48, 8, size.width - 10, size.height - 25);
    final peak = points.map((p) => p.watts).reduce((a, b) => math.max(a, b));
    final scale = math.max(100.0, peak);
    final grid = Paint()..color = colors.outlineVariant;
    for (var i = 0; i <= 4; i++) {
      final y = plot.bottom - plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _label(
        canvas,
        (scale * (i / 4)).toStringAsFixed(0),
        Offset(0, y - 6),
        45,
      );
    }
    final first = start;
    final last = end;
    final span = last.difference(first).inMicroseconds;
    final offsets = points.map((p) {
      final fraction = span <= 0
          ? 0.5
          : p.endedAt.difference(first).inMicroseconds / span;
      return Offset(
        plot.left + plot.width * fraction,
        plot.bottom - plot.height * (p.watts / scale),
      );
    }).toList();
    final line = Paint()
      ..color = colors.primary
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (var i = 1; i < offsets.length; i++) {
      final p = offsets[i];
      if (points[i].startedAt == points[i - 1].endedAt) {
        path.lineTo(p.dx, p.dy);
      } else {
        path.moveTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, line);
    final dot = Paint()..color = colors.primary;
    for (final p in offsets) {
      canvas.drawCircle(p, 3, dot);
    }
    _label(canvas, _clock(first), Offset(plot.left, plot.bottom + 6), 48);
    if (span > 0) {
      _label(
        canvas,
        _clock(last),
        Offset(plot.right - 34, plot.bottom + 6),
        40,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UsagePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.colors != colors ||
      oldDelegate.start != start ||
      oldDelegate.end != end;
}
