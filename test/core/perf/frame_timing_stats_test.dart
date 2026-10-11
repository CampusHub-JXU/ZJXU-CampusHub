import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/perf/frame_timing_stats.dart';

FrameTimingSample sample({
  double ui = 2,
  double raster = 3,
  double total = 5,
  double vsync = 0.2,
  int offset = 0,
}) {
  return FrameTimingSample(
    vsyncOffsetMicros: offset,
    uiBuildMs: ui,
    rasterMs: raster,
    totalSpanMs: total,
    vsyncOverheadMs: vsync,
  );
}

void main() {
  group('120Hz 预算常量', () {
    test('固定为 1000/120，不随系统刷新率改变', () {
      expect(kPerfFrameBudget120HzMs, closeTo(8.3333, 0.0001));
      expect(kPerfFrameBudget120HzMs, 1000 / 120);
    });

    test('超预算标签写明不是系统掉帧总数', () {
      expect(kPerfOverBudgetLabel, contains('非系统掉帧总数'));
    });
  });

  group('nearest-rank 分位数', () {
    test('空数组返回 NaN（调用方必须先判空）', () {
      expect(nearestRankPercentile(const <double>[], 50).isNaN, isTrue);
    });

    test('单元素：任何分位数都等于该值', () {
      for (final p in const [0.0, 1.0, 50.0, 99.0, 100.0]) {
        expect(nearestRankPercentile(const <double>[7.5], p), 7.5);
      }
    });

    test('0 / 100 取最小 / 最大', () {
      final sorted = <double>[1, 2, 3, 4];
      expect(nearestRankPercentile(sorted, 0), 1);
      expect(nearestRankPercentile(sorted, -5), 1);
      expect(nearestRankPercentile(sorted, 100), 4);
      expect(nearestRankPercentile(sorted, 1000), 4);
    });

    test('取秩定义：ceil(p/100*n) 名', () {
      final sorted = <double>[1, 2, 3, 4];
      expect(nearestRankPercentile(sorted, 25), 1);
      expect(nearestRankPercentile(sorted, 50), 2);
      expect(nearestRankPercentile(sorted, 75), 3);
      expect(nearestRankPercentile(sorted, 99), 4);
    });
  });

  group('computeFrameTimingStats', () {
    test('空输入 = 空统计，没有 NaN 与除零', () {
      final stats = computeFrameTimingStats(const <FrameTimingSample>[]);
      expect(stats.count, 0);
      expect(stats.uiBuildP50, isNull);
      expect(stats.totalSpanMax, isNull);
      expect(stats.buildOverBudgetFraction, 0);
      expect(stats.rasterOverBudgetFraction, 0);
      expect(stats.totalOverBudgetFraction, 0);
      expect(stats.budgetMs, kPerfFrameBudget120HzMs);
    });

    test('单样本：所有分位数等于该样本', () {
      final stats = computeFrameTimingStats(<FrameTimingSample>[
        sample(ui: 2.5, raster: 4.5, total: 7.5, vsync: 0.5),
      ]);
      expect(stats.count, 1);
      expect(stats.uiBuildP50, 2.5);
      expect(stats.uiBuildP95, 2.5);
      expect(stats.uiBuildP99, 2.5);
      expect(stats.uiBuildMax, 2.5);
      expect(stats.rasterP99, 4.5);
      expect(stats.totalSpanP50, 7.5);
      expect(stats.vsyncOverheadMax, 0.5);
    });

    test('分位数与最大值的排序无关（输入乱序也正确）', () {
      final stats = computeFrameTimingStats(<FrameTimingSample>[
        sample(total: 30),
        sample(total: 10),
        sample(total: 20),
        sample(total: 40),
      ]);
      expect(stats.totalSpanP50, 20);
      expect(stats.totalSpanP95, 40);
      expect(stats.totalSpanMax, 40);
    });

    test('超预算比例用固定 8.333 ms 预算，与 build/raster/总跨度分别统计', () {
      final stats = computeFrameTimingStats(<FrameTimingSample>[
        sample(ui: 5, raster: 5, total: 5),
        sample(ui: 9, raster: 9, total: 9),
        sample(ui: 9, raster: 1, total: 9),
        sample(ui: 1, raster: 1, total: 1),
      ]);
      expect(stats.count, 4);
      expect(stats.buildOverBudgetFraction, closeTo(2 / 4, 1e-9));
      expect(stats.rasterOverBudgetFraction, closeTo(1 / 4, 1e-9));
      expect(stats.totalOverBudgetFraction, closeTo(2 / 4, 1e-9));
      expect(stats.budgetMs, kPerfFrameBudget120HzMs);
    });

    test('非法预算回退到 120Hz 常量，不产生 NaN / 除零', () {
      for (final bad in const [0.0, -1.0, double.nan, double.infinity]) {
        final stats = computeFrameTimingStats(<FrameTimingSample>[
          sample(total: 9),
        ], budgetMs: bad);
        expect(stats.budgetMs, kPerfFrameBudget120HzMs);
        expect(stats.totalOverBudgetFraction, 1.0);
      }
    });

    test('所有输出都是有限数', () {
      final stats = computeFrameTimingStats(<FrameTimingSample>[
        sample(),
        sample(total: 12.5),
      ]);
      final values = <double?>[
        stats.uiBuildP50,
        stats.uiBuildP95,
        stats.uiBuildP99,
        stats.uiBuildMax,
        stats.rasterP50,
        stats.totalSpanP99,
        stats.vsyncOverheadP50,
        stats.buildOverBudgetFraction,
        stats.rasterOverBudgetFraction,
        stats.totalOverBudgetFraction,
        stats.budgetMs,
      ];
      for (final value in values) {
        expect(value, isNotNull);
        expect(value!.isFinite, isTrue);
      }
    });
  });

  group('展示格式化', () {
    test('毫秒：一位小数，null / 非有限显示占位符', () {
      expect(formatPerfMs(2.34), '2.3');
      expect(formatPerfMs(null), '—');
      expect(formatPerfMs(double.nan), '—');
      expect(formatPerfMs(double.infinity), '—');
    });

    test('百分比：一位小数', () {
      expect(formatPerfPercent(0.125), '12.5%');
      expect(formatPerfPercent(0), '0.0%');
    });

    test('计数：千分位', () {
      expect(formatPerfCount(0), '0');
      expect(formatPerfCount(999), '999');
      expect(formatPerfCount(5000), '5,000');
      expect(formatPerfCount(1234567), '1,234,567');
    });

    test('时长：秒与分秒', () {
      expect(formatPerfDuration(const Duration(milliseconds: 0)), '0.0s');
      expect(formatPerfDuration(const Duration(milliseconds: 12345)), '12.3s');
      expect(formatPerfDuration(const Duration(seconds: 65)), '1m05s');
      expect(formatPerfDuration(const Duration(seconds: -1)), '0.0s');
    });
  });
}
