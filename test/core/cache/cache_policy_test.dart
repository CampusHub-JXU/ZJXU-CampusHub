import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/cache/cache_policy.dart';

const _volatile = CachePolicy(ttl: Duration.zero, staleGrace: Duration.zero);

void main() {
  group('预设档位', () {
    test('catalog 面向一学期也未必变一次的目录数据', () {
      const policy = CachePolicy.catalog;

      expect(policy.ttl, const Duration(days: 30));
      expect(policy.staleGrace, const Duration(days: 60));
      expect(policy.isVolatile, isFalse);
    });
  });

  group('isVolatile', () {
    test('只有 ttl 非正的档位才算实时型', () {
      expect(_volatile.isVolatile, isTrue);
      expect(CachePolicy.catalog.isVolatile, isFalse);
    });

    test('自定义策略按 ttl 是否为正判定', () {
      expect(
        const CachePolicy(
          ttl: Duration(minutes: 1),
          staleGrace: Duration.zero,
        ).isVolatile,
        isFalse,
      );
      expect(
        const CachePolicy(
          ttl: Duration.zero,
          staleGrace: Duration(days: 1),
        ).isVolatile,
        isTrue,
      );
    });
  });

  group('freshnessOf 边界', () {
    const policy = CachePolicy(
      ttl: Duration(minutes: 10),
      staleGrace: Duration(minutes: 5),
    );

    test('age 为 0 视为新鲜', () {
      expect(policy.freshnessOf(Duration.zero), CacheFreshness.fresh);
    });

    test('时钟回拨导致的负 age 视为新鲜', () {
      expect(
        policy.freshnessOf(const Duration(minutes: -1)),
        CacheFreshness.fresh,
      );
    });

    test('age 恰好等于 ttl 仍算新鲜（闭区间）', () {
      expect(policy.freshnessOf(policy.ttl), CacheFreshness.fresh);
    });

    test('age 刚过 ttl 进入 stale', () {
      expect(
        policy.freshnessOf(policy.ttl + const Duration(milliseconds: 1)),
        CacheFreshness.stale,
      );
    });

    test('age 落在宽限窗内为 stale', () {
      expect(
        policy.freshnessOf(policy.ttl + const Duration(minutes: 2)),
        CacheFreshness.stale,
      );
    });

    test('age 恰好等于 ttl + staleGrace 仍算 stale（闭区间）', () {
      expect(
        policy.freshnessOf(policy.ttl + policy.staleGrace),
        CacheFreshness.stale,
      );
    });

    test('age 超过 ttl + staleGrace 判定为 expired', () {
      expect(
        policy.freshnessOf(
          policy.ttl + policy.staleGrace + const Duration(milliseconds: 1),
        ),
        CacheFreshness.expired,
      );
    });

    test('远超宽限窗判定为 expired', () {
      expect(
        policy.freshnessOf(const Duration(days: 30)),
        CacheFreshness.expired,
      );
    });
  });

  group('零宽限窗策略', () {
    const policy = CachePolicy(
      ttl: Duration(minutes: 10),
      staleGrace: Duration.zero,
    );

    test('ttl 之后没有 stale 过渡，直接 expired', () {
      expect(policy.freshnessOf(policy.ttl), CacheFreshness.fresh);
      expect(
        policy.freshnessOf(policy.ttl + const Duration(milliseconds: 1)),
        CacheFreshness.expired,
      );
    });
  });

  group('volatile 策略', () {
    test('age 为 0 的一瞬间仍判 fresh', () {
      expect(_volatile.freshnessOf(Duration.zero), CacheFreshness.fresh);
    });

    test('任何正的 age 立即 expired，且不存在 stale 过渡', () {
      expect(
        _volatile.freshnessOf(const Duration(microseconds: 1)),
        CacheFreshness.expired,
      );
      expect(
        _volatile.freshnessOf(const Duration(hours: 1)),
        CacheFreshness.expired,
      );
    });
  });

  group('各预设档位的实际跨度', () {
    test('catalog 在断网时仍能兜底 90 天', () {
      const policy = CachePolicy.catalog;

      expect(
        policy.freshnessOf(const Duration(days: 29)),
        CacheFreshness.fresh,
      );
      expect(
        policy.freshnessOf(const Duration(days: 31)),
        CacheFreshness.stale,
      );
      expect(
        policy.freshnessOf(const Duration(days: 89)),
        CacheFreshness.stale,
      );
      expect(
        policy.freshnessOf(const Duration(days: 91)),
        CacheFreshness.expired,
      );
    });
  });
}
