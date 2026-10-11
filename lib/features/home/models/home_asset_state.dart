/// 首页资产行（校园卡余额 / 宿舍电费）单项的获取状态。
///
/// 刻意独立于「字符串能否解析成数字」：`--` 既可能是未登录、未配置、
/// 正在获取或获取失败，不能再用数值解析推断加载态。校园卡与宿舍电费各自
/// 持有独立实例，一项失败 / 刷新不影响另一项。
enum HomeAssetPhase {
  /// 冷启动 / 身份恢复中：尚未确定统一认证身份，也没发起过真实请求。
  recovering,

  /// 未登录：等待用户完成统一认证，登录成功后自动更新。
  waiting,

  /// 正在真正获取，且当前没有可展示的缓存值。
  loading,

  /// 有可展示的缓存值，后台正在刷新（保留旧值，绝不闪回占位符）。
  refreshing,

  /// 有可展示的值，当前没有进行中的请求。
  ready,

  /// 无可展示值且请求失败：可重试，禁止无限加载。
  error,

  /// 明确的配置缺失（如未选择寝室房间），绝不伪装成加载中。
  notConfigured,
}

/// 单项资产的状态 + 可展示值。
///
/// 由首页按当前真实任务生命周期派生（服务缓存 / 在途请求 / 身份 / 配置），
/// 经 `HomeSnapshot` → `resolveHomePresentation` → `HomeStatusPresentation`
/// 传到资产行，不再从字符串反推。
class HomeAssetState {
  const HomeAssetState._({required this.phase, this.value});

  /// 冷启动 / 身份恢复中。
  const HomeAssetState.recovering() : this._(phase: HomeAssetPhase.recovering);

  /// 未登录等待中。
  const HomeAssetState.waiting() : this._(phase: HomeAssetPhase.waiting);

  /// 首次获取中（当前无缓存值）。
  const HomeAssetState.loading() : this._(phase: HomeAssetPhase.loading);

  /// 有缓存值，后台刷新中。
  const HomeAssetState.refreshing(String value)
    : this._(phase: HomeAssetPhase.refreshing, value: value);

  /// 已就绪的值。
  const HomeAssetState.ready(String value)
    : this._(phase: HomeAssetPhase.ready, value: value);

  /// 获取失败（当前无缓存可展示）。
  const HomeAssetState.error() : this._(phase: HomeAssetPhase.error);

  /// 配置缺失（如未设置寝室）。
  const HomeAssetState.notConfigured()
    : this._(phase: HomeAssetPhase.notConfigured);

  final HomeAssetPhase phase;

  /// 可展示的值文本（如 `'23.5'`、`'42'`）；[ready] / [refreshing] 之外为 null。
  final String? value;

  bool get hasValue => value != null;

  /// 是否有真实请求在途（决定是否渲染小转圈；等待 / 恢复态不转圈）。
  bool get isBusy =>
      phase == HomeAssetPhase.loading || phase == HomeAssetPhase.refreshing;

  /// 有缓存值且后台刷新中。
  bool get isRefreshing => phase == HomeAssetPhase.refreshing;

  @override
  bool operator ==(Object other) =>
      other is HomeAssetState && other.phase == phase && other.value == value;

  @override
  int get hashCode => Object.hash(phase, value);

  @override
  String toString() =>
      'HomeAssetState(${phase.name}${value == null ? '' : ', $value'})';
}
