/// 缓存新鲜度策略定义。
///
/// 学校侧的目录型数据（园区 / 楼幢 / 房间 / 活动分类）与动态数据（余额 /
/// 成绩）变化频率差了两个数量级，共用一套 TTL 必然两头不讨好：目录缓存
/// 半小时等于没缓存，余额缓存三十天会一直显示错数。这里把策略收敛成
/// 四档，业务侧只挑档位，不自己写过期判定。
library;

/// 缓存条目相对其 [CachePolicy.ttl] 所处的新鲜度。
enum CacheFreshness {
  /// 新鲜：直接命中，不发请求。
  fresh,

  /// 过期但在宽限窗内：可以先用旧值顶上，同时后台静默刷新
  /// （stale-while-revalidate）。
  stale,

  /// 已失效：旧值不再可用，必须等网络结果。
  expired,
}

class CachePolicy {
  const CachePolicy({required this.ttl, required this.staleGrace});

  /// 数据在 [ttl] 内视为新鲜，读缓存直接返回，不触网。
  final Duration ttl;

  /// 超过 [ttl] 之后仍允许「先用旧值顶上」的宽限期。
  ///
  /// 超过 `ttl + staleGrace` 的条目等同于不存在——目录类数据放长一点，
  /// 断网时也能打开页面；余额一类放短，避免长期展示离谱的数字。
  final Duration staleGrace;

  /// 目录型：园区 / 楼幢 / 楼层 / 房间、活动分类等，一学期也未必变一次。
  static const catalog = CachePolicy(
    ttl: Duration(days: 30),
    staleGrace: Duration(days: 60),
  );

  /// 日更型：通知列表、活动列表。当天内重复打开不必重拉。
  static const daily = CachePolicy(
    ttl: Duration(hours: 8),
    staleGrace: Duration(days: 3),
  );

  /// 会话型：余额一类，半小时内重复看没意义，但断网时能兜底。
  static const session = CachePolicy(
    ttl: Duration(minutes: 30),
    staleGrace: Duration(days: 1),
  );

  /// 实时型：不缓存，每次都取（成绩、考试安排等）。
  static const volatile = CachePolicy(
    ttl: Duration.zero,
    staleGrace: Duration.zero,
  );

  bool get isVolatile => ttl <= Duration.zero;

  /// 判定年龄为 [age] 的条目处于哪一档。
  CacheFreshness freshnessOf(Duration age) {
    if (age <= ttl) return CacheFreshness.fresh;
    if (age <= ttl + staleGrace) return CacheFreshness.stale;
    return CacheFreshness.expired;
  }
}
