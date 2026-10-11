import 'dart:math' as math;

/// 120 Hz 理论帧间隔（毫秒）：1000 / 120 ≈ 8.333333。
///
/// 只作为「超过理论间隔」的固定参照预算，不代表系统真实刷新率——
/// 真实刷新率单独记录在报告元数据里，两者不可互相替代。
const double kPerfFrameBudget120HzMs = 1000 / 120;

/// 超过理论间隔的比例标签。刻意写全，避免被读成「系统掉帧总数」。
const String kPerfOverBudgetLabel = '超过120Hz理论间隔比例，非系统掉帧总数';

/// 单帧原始时长的只读快照（毫秒）。
///
/// [vsyncOffsetMicros] 是相对本次运行起点的偏移（原始单调时钟域），
/// 不是墙钟时间，也不含任何设备/账号信息。
class FrameTimingSample {
  const FrameTimingSample({
    required this.vsyncOffsetMicros,
    required this.uiBuildMs,
    required this.rasterMs,
    required this.totalSpanMs,
    required this.vsyncOverheadMs,
  });

  final int vsyncOffsetMicros;
  final double uiBuildMs;
  final double rasterMs;
  final double totalSpanMs;
  final double vsyncOverheadMs;
}

/// 一组帧时长的诚实统计。
///
/// 所有分位数都按 [nearestRankPercentile] 计算；[count] 为 0 时所有分位数为
/// `null`（UI 显示占位符），不会产生 NaN / 除零。
///
/// [totalSpanP50] 等描述的是「vsync 到 raster 结束」的流水线跨度
/// （`FrameTiming.totalSpan`），**不是** build + raster 相加，也不是 GPU 真实耗时。
class FrameTimingStats {
  const FrameTimingStats({
    required this.count,
    required this.uiBuildP50,
    required this.uiBuildP95,
    required this.uiBuildP99,
    required this.uiBuildMax,
    required this.rasterP50,
    required this.rasterP95,
    required this.rasterP99,
    required this.rasterMax,
    required this.totalSpanP50,
    required this.totalSpanP95,
    required this.totalSpanP99,
    required this.totalSpanMax,
    required this.vsyncOverheadP50,
    required this.vsyncOverheadP95,
    required this.vsyncOverheadP99,
    required this.vsyncOverheadMax,
    required this.buildOverBudgetFraction,
    required this.rasterOverBudgetFraction,
    required this.totalOverBudgetFraction,
    required this.budgetMs,
  });

  final int count;

  final double? uiBuildP50;
  final double? uiBuildP95;
  final double? uiBuildP99;
  final double? uiBuildMax;

  final double? rasterP50;
  final double? rasterP95;
  final double? rasterP99;
  final double? rasterMax;

  final double? totalSpanP50;
  final double? totalSpanP95;
  final double? totalSpanP99;
  final double? totalSpanMax;

  final double? vsyncOverheadP50;
  final double? vsyncOverheadP95;
  final double? vsyncOverheadP99;
  final double? vsyncOverheadMax;

  /// 超过 [budgetMs] 的帧占比（0..1）。见 [kPerfOverBudgetLabel]。
  final double buildOverBudgetFraction;
  final double rasterOverBudgetFraction;
  final double totalOverBudgetFraction;

  final double budgetMs;

  static const FrameTimingStats empty = FrameTimingStats(
    count: 0,
    uiBuildP50: null,
    uiBuildP95: null,
    uiBuildP99: null,
    uiBuildMax: null,
    rasterP50: null,
    rasterP95: null,
    rasterP99: null,
    rasterMax: null,
    totalSpanP50: null,
    totalSpanP95: null,
    totalSpanP99: null,
    totalSpanMax: null,
    vsyncOverheadP50: null,
    vsyncOverheadP95: null,
    vsyncOverheadP99: null,
    vsyncOverheadMax: null,
    buildOverBudgetFraction: 0,
    rasterOverBudgetFraction: 0,
    totalOverBudgetFraction: 0,
    budgetMs: kPerfFrameBudget120HzMs,
  );
}

/// nearest-rank 分位数：对升序数组取 `ceil(p/100 * n)` 名，越界夹到 1..n。
///
/// 定义显式写死，避免不同实现（插值 vs 取秩）在极值上打架：
/// * `p <= 0` → 最小值；`p >= 100` → 最大值；
/// * `n == 1` → 该唯一值；
/// * `n == 0` → 返回 NaN，调用方必须先判空（本函数不做业务兜底）。
///
/// 入参 [sorted] 必须已升序。
double nearestRankPercentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return double.nan;
  if (sorted.length == 1) return sorted.first;
  if (p <= 0) return sorted.first;
  if (p >= 100) return sorted.last;
  final rank = (p / 100.0 * sorted.length).ceil();
  final index = rank.clamp(1, sorted.length) - 1;
  return sorted[index];
}

double? _max(List<double> values) => values.isEmpty ? null : values.last;

/// 由原始样本计算统计。空输入返回 [FrameTimingStats.empty]。
FrameTimingStats computeFrameTimingStats(
  List<FrameTimingSample> samples, {
  double budgetMs = kPerfFrameBudget120HzMs,
}) {
  if (samples.isEmpty) return FrameTimingStats.empty;

  final ui = <double>[];
  final raster = <double>[];
  final total = <double>[];
  final vsync = <double>[];
  for (final s in samples) {
    ui.add(s.uiBuildMs);
    raster.add(s.rasterMs);
    total.add(s.totalSpanMs);
    vsync.add(s.vsyncOverheadMs);
  }
  ui.sort();
  raster.sort();
  total.sort();
  vsync.sort();

  final safeBudget = budgetMs.isFinite && budgetMs > 0
      ? budgetMs
      : kPerfFrameBudget120HzMs;

  double overFraction(List<double> sorted) {
    var over = 0;
    for (final v in sorted) {
      if (v > safeBudget) over++;
    }
    return over / sorted.length;
  }

  return FrameTimingStats(
    count: samples.length,
    uiBuildP50: nearestRankPercentile(ui, 50),
    uiBuildP95: nearestRankPercentile(ui, 95),
    uiBuildP99: nearestRankPercentile(ui, 99),
    uiBuildMax: _max(ui),
    rasterP50: nearestRankPercentile(raster, 50),
    rasterP95: nearestRankPercentile(raster, 95),
    rasterP99: nearestRankPercentile(raster, 99),
    rasterMax: _max(raster),
    totalSpanP50: nearestRankPercentile(total, 50),
    totalSpanP95: nearestRankPercentile(total, 95),
    totalSpanP99: nearestRankPercentile(total, 99),
    totalSpanMax: _max(total),
    vsyncOverheadP50: nearestRankPercentile(vsync, 50),
    vsyncOverheadP95: nearestRankPercentile(vsync, 95),
    vsyncOverheadP99: nearestRankPercentile(vsync, 99),
    vsyncOverheadMax: _max(vsync),
    buildOverBudgetFraction: overFraction(ui),
    rasterOverBudgetFraction: overFraction(raster),
    totalOverBudgetFraction: overFraction(total),
    budgetMs: safeBudget,
  );
}

/// 毫秒数值的固定展示：一位小数（如 `8.3`）。`null` → `—`。
String formatPerfMs(double? value) {
  if (value == null || !value.isFinite) return '—';
  return value.toStringAsFixed(1);
}

/// 比例展示：一位小数百分比（如 `12.5%`）。
String formatPerfPercent(double fraction) {
  if (!fraction.isFinite) return '—';
  return '${(fraction * 100).toStringAsFixed(1)}%';
}

/// 千分位整数（如 `4,321`），仅用于展示，不参与导出。
String formatPerfCount(int value) {
  final text = value.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return value < 0 ? '-$buffer' : buffer.toString();
}

/// 时长展示：`12.3s` / `1m05s`。
String formatPerfDuration(Duration duration) {
  final ms = math.max(0, duration.inMilliseconds);
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
}
