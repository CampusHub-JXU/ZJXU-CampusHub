import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/auth/auth_session_persistence.dart';
import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/credential_store.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/private_cache_store.dart';
import '../../core/epay100/epay100_gateway.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import '../../core/system_surface/campus_data_change_bus.dart';
import 'campus_card_bill_gateway.dart';
import 'campus_card_consumption.dart';

/// 余额查询失败类型。
///
/// - [authRequired]：当前**没有**可用的统一认证身份（或本域没有可用持久身份），
///   尚未发起任何请求；与 [authExpired] 区分。
/// - [authExpired]：共享网关明确报告会话失效（`EpaySessionUnavailableException`）。
/// - [serviceUnavailable] / [network]：业务 / 传输失败，**不代表**登录失效。
enum BalanceFailureKind {
  none,
  authRequired,
  authExpired,
  serviceUnavailable,
  network,
}

/// `app.portal.getBillList` 单条交易的标准化视图（**渠道充值流水**）。
///
/// 实证字段（2026-11-19，「余额充值 -120」一条）：`pay_time`
/// （`yyyy-MM-dd HH:mm:ss`）、`real_fee_pay`/`fee_pay`（**实付带符号**，
/// 负=从渠道扣的钱）、`pre_title`/`remark`（名目）、`type_name`（服务端
/// 记账分类：消费/充值…）、`pay_name`（渠道显示名）、`pay_type`（渠道码）、
/// `pay_week`（星期）、`fee_total`/`fee_attach`/`fee_subsidy`/`fee_refund`。
/// 注意「余额充值」业务是钱**进**卡，`real_fee_pay=-120` 是银行卡实付。
///
/// 这不是卡内消费：真实消费见 [CampusCardConsumptionEntry]（FineReport 账单）。
/// 本类与 [CampusCardService.fetchBillList] 保留待清理——v0.12.3 起页面
/// 「最近账单」内嵌区块已挂起（它展示的本就是这条充值流水，语义不对），
/// 恢复时整体改用 [CampusCardService.fetchConsumption]。
class CampusCardBillEntry {
  const CampusCardBillEntry({
    required this.payTime,
    required this.title,
    required this.amount,
    this.payType = '',
    this.payName = '',
    this.typeName = '',
    this.type = 0,
  });

  factory CampusCardBillEntry.fromJson(Map<String, dynamic> json) {
    final title = (json['pre_title'] ?? json['remark'] ?? '').toString().trim();
    return CampusCardBillEntry(
      payTime: _parseTime(json['pay_time']),
      title: title.isEmpty ? '交易' : title,
      amount: _toDouble(json['real_fee_pay'] ?? json['fee_pay']),
      payType: (json['pay_type'] ?? '').toString(),
      payName: (json['pay_name'] ?? '').toString(),
      typeName: (json['type_name'] ?? '').toString(),
      type: _toInt(json['type']),
    );
  }

  /// 交易时间；解析失败回退 epoch，由展示层决定显隐。
  final DateTime payTime;
  final String title;

  /// 实付带符号金额（负=渠道扣款；「充值」对卡是进账、对账单是支出）。
  final double amount;

  /// 渠道码（如 `pay_bank_ccb`、`pay_yktpay`），空=未知。
  final String payType;

  /// 渠道显示名（如「建行支付」），空=未知。
  final String payName;

  /// 服务端记账分类（消费/充值…），空=未知。比 `type` 码更可靠。
  final String typeName;

  /// 业务类型码，原样保留供扩展。
  final int type;

  /// 是否为充值类条目（名目含「充值」或服务端分类=充值）。
  bool get isRecharge => typeName.contains('充值') || title.contains('充值');

  static DateTime _parseTime(Object? v) {
    final s = (v ?? '').toString().trim();
    if (s.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.tryParse(s.replaceFirst(' ', 'T')) ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse((v ?? '0').toString()) ?? 0;
  }

  static int _toInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '0').toString()) ?? 0;
  }
}

class CampusCardService {
  CampusCardService._() {    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
  }

  static final CampusCardService instance = CampusCardService._();

  static const _storage = FlutterSecureStorage();

  /// 单条原子 JSON envelope（owner + updatedAt + durable epoch + payload）。
  static const cacheKey = 'zjxu_campus_card_private_v1';

  // 旧多 key / 旧无 epoch 格式：无法证明属于哪个持久身份纪元，安全舍弃。
  static const _legacyBalanceKey = 'zjxu_campus_card_balance';
  static const _legacyOwnerKey = 'zjxu_campus_card_balance_owner';
  static const _legacyUpdatedAtKey = 'zjxu_campus_card_balance_updated_at';

  static final PrivateCacheStore _store = SecureStoragePrivateCacheStore(
    cacheKey,
  );

  /// 余额缓存有效期：5 分钟（供 resume 协调）。
  static const refreshWindow = Duration(minutes: 5);

  /// 余额 RPC：epay100 `cardService/index` 页面取卡内余额所用 method，
  /// 无 data 参数，响应 `data.balance`。
  static const _balanceMethod = 'app.yktservice.getBalance';

  /// 账单快照（四格统计 + 近期消费 + 三餐 / 单日统计）的缓存有效期。
  /// 与余额同档、只放内存，不做磁盘持久化（消费流水属于敏感账目）。
  static const consumptionRefreshWindow = Duration(minutes: 5);

  /// 校园卡主页「最近消费」内嵌预览条数上限；完整账单在原生账单页 / H5。
  static const consumptionPreviewLimit = 4;

  /// 旧「最近账单」（充值流水）预览窗口：服务端要求起止间隔 ≤31 天。
  /// 仅遗留内嵌区块使用，真实消费不走这里。
  static const billPreviewDays = 30;

  /// 旧内嵌预览条数上限。
  static const billPreviewLimit = 4;

  /// 旧预览内存缓存有效期（不落盘）。
  static const billRefreshWindow = Duration(minutes: 5);

  double? _cachedBalance;
  DateTime? _lastUpdated;
  String? _cachedOwner;
  int? _cachedEpoch;
  BalanceFailureKind _lastBalanceFailure = BalanceFailureKind.none;

  /// 账单快照进程内缓存（不落盘）：owner 归属校验 + 采纳侧 epoch 守卫。
  CampusCardConsumptionSummary? _cachedConsumption;
  String? _cachedConsumptionOwner;
  DateTime? _consumptionUpdatedAt;
  int _latestConsumptionFetch = 0;

  /// 旧「充值流水」预览进程内缓存（遗留内嵌区块专用，见 [CampusCardBillEntry]）。
  List<CampusCardBillEntry>? _cachedBillEntries;
  String? _cachedBillOwner;
  DateTime? _billUpdatedAt;
  int _latestBillFetch = 0;

  /// 当前有效的持久身份纪元（最近一次读到 durable session 的 epoch）。
  int? _validEpoch;

  _BalanceInFlight? _inFlight;
  int _latestGeneration = 0;

  /// 身份上下文世代：统一认证通知 / 已观测 durable epoch 更换 / fail-closed
  /// 时递增，普通请求分配（[_latestGeneration]）不影响它。用于 await 边界判断
  /// 「捕获的身份上下文是否仍然有效」，避免并发抓取互相误伤。
  int _identityEpoch = 0;

  /// 测试注入：restore 读取持久 epoch 之后、获取同域锁之前的屏障。
  @visibleForTesting
  Future<void> Function()? debugRestoreBarrier;

  /// 测试注入：durable session 读取返回之后、采纳结果之前的屏障
  /// （验证读取期间身份变化时迟到读取不被采纳）。
  @visibleForTesting
  Future<void> Function()? debugDurableReadBarrier;

  /// 统一认证身份修订号：登录 / 登出 / 换号 / 恢复时递增，异步期间发生
  /// 变化的旧结果一律丢弃。仅进程内有效。
  int get _authRevision => UnifiedAuthService.instance.sessionRevision;

  @visibleForTesting
  Future<double?> Function()? debugBalanceFetcher;

  /// 测试注入：替代 [CampusCardService.fetchConsumption] 的真实网关抓取；返回
  /// 非 null 的快照会走归属守卫写入内存缓存（抛异常 → 抓取失败返回 null）。
  @visibleForTesting
  Future<CampusCardConsumptionSummary?> Function()? debugConsumptionFetcher;

  /// 测试注入：替代 [CampusCardBillGateway.fetch] 的原始响应抓取。
  @visibleForTesting
  Future<CampusCardBillRawPayload> Function()? debugBillRawFetcher;

  /// 测试注入：替代旧「充值流水」预览抓取（遗留内嵌区块）。
  @visibleForTesting
  Future<List<CampusCardBillEntry>> Function()? debugBillFetcher;

  @visibleForTesting
  Epay100Gateway? debugGateway;

  Epay100Gateway get _gateway => debugGateway ?? Epay100Gateway.instance;

  /// 必须已登录且账号非空；否则视为没有明确 CAS owner。
  String? get _currentAccount => UnifiedAuthService.instance.verifiedAccount;

  /// 统一认证 identity 发生变化时 notify：清内存缓存，并**前推本地
  /// generation**作废所有在途请求——同账号重登时 `sessionRevision` 可能不增，
  /// 只有本地世代号能保证旧请求不被复用、迟到结果（含 error）不污染新会话。
  void _onUnifiedAuthChanged() {
    _identityEpoch++;
    _invalidateInFlightRequests();
    _clearMemoryCache();
    _validEpoch = null;
    _lastBalanceFailure = BalanceFailureKind.none;
  }

  /// 递增本地 generation 并丢弃 inflight 引用：已发起请求立即失效，新请求
  /// 不得复用旧 future（旧 future 的 whenComplete 也不会清掉新 inflight）。
  void _invalidateInFlightRequests() {
    _latestGeneration++;
    _inFlight = null;
  }

  void _clearMemoryCache() {
    _cachedBalance = null;
    _lastUpdated = null;
    _cachedOwner = null;
    _cachedEpoch = null;
    _cachedConsumption = null;
    _cachedConsumptionOwner = null;
    _consumptionUpdatedAt = null;
    _latestConsumptionFetch++;
    _cachedBillEntries = null;
    _cachedBillOwner = null;
    _billUpdatedAt = null;
    _latestBillFetch++;
  }

  /// 记录当前 durable epoch；识别到纪元更换（跨 isolate 登出/重登、同账号
  /// 重登）即失效内存缓存并作废在途请求，避免旧结果复活。
  void _observeDurableEpoch(int epoch) {
    if (_validEpoch != null && _validEpoch != epoch) {
      _identityEpoch++;
      _clearMemoryCache();
      _invalidateInFlightRequests();
    } else if (_cachedEpoch != null && _cachedEpoch != epoch) {
      _clearMemoryCache();
    }
    _validEpoch = epoch;
  }

  /// 持久身份缺失 / 不匹配时的 fail-closed：仅当捕获的账号 / revision /
  /// 身份世代 / generation 仍是当前上下文时，清掉**当前**内存余额与有效
  /// epoch、作废在途请求，并标记 authRequired。不删磁盘缓存（可能属于其他
  /// 身份 / 纪元），不做全局登出，也不臆测 authExpired。
  void _failClosedAuthRequired({
    required String account,
    required int revision,
    required int identityEpoch,
    required int generation,
  }) {
    if (_currentAccount != account) return;
    if (_authRevision != revision) return;
    if (_identityEpoch != identityEpoch) return;
    if (_latestGeneration != generation) return;
    _identityEpoch++;
    _clearMemoryCache();
    _validEpoch = null;
    _invalidateInFlightRequests();
    _lastBalanceFailure = BalanceFailureKind.authRequired;
  }

  /// 采纳一次 durable session 读取结果前的守卫：捕获的账号 / revision /
  /// 身份世代必须仍是当前上下文；读到的 epoch 早于已观测 epoch 说明读取
  /// 已过期（期间纪元被推进），一律丢弃。
  bool _canAdoptDurableRead({
    required String account,
    required int revision,
    required int identityEpoch,
    required int durableEpoch,
  }) {
    if (_identityEpoch != identityEpoch) return false;
    if (_authRevision != revision) return false;
    if (_currentAccount != account) return false;
    final observed = _validEpoch;
    if (observed != null && durableEpoch < observed) return false;
    return true;
  }

  /// owner 为 null 时禁止展示；归属与当前 CAS 账号不一致、或 epoch 已不是
  /// 当前有效持久 epoch 时也禁止展示（fail closed）。
  double? get cachedBalance {
    final balance = _cachedBalance;
    if (balance == null) return null;
    final owner = _cachedOwner;
    if (owner == null || owner != _currentAccount) return null;
    if (_cachedEpoch == null || _cachedEpoch != _validEpoch) return null;
    return balance;
  }

  DateTime? get lastUpdated => _lastUpdated;

  /// 最近一次余额查询的失败类型。没有明确统一认证身份时**按当前身份派生**
  /// 为 [BalanceFailureKind.authRequired]（页面首次 build 即可读到，无需先点
  /// 一次查询）；有身份时返回最近一次请求记录的失败（成功 / 身份变化后为
  /// [BalanceFailureKind.none]）。
  BalanceFailureKind get lastBalanceFailure => _currentAccount == null
      ? BalanceFailureKind.authRequired
      : _lastBalanceFailure;

  bool get isStale {
    if (_cachedBalance == null) return true;
    final updatedAt = _lastUpdated;
    if (updatedAt == null) return true;
    return DateTime.now().difference(updatedAt) >= refreshWindow;
  }

  static const statusPageUrl =
      'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5&viewlet=xxkj%252Fmobile%252Fykt.frm#/form';

  /// CAS service URL — fragment (#/form) 不能包含在 service 参数里，
  /// 否则 ticket 验证时 service 不匹配导致认证失败。
  /// URL 注册表统一收敛在 [CasService]。
  static final statusPageCasServiceUrl = CasService.campusCardStatus.serviceUrl;

  /// 持久身份快照：必须 active 且账号与 [account] 一致，否则 fail closed。
  Future<CredentialSessionEnvelope?> _readDurableSession(String account) async {
    final durable = await AuthSessionPersistence.instance.read(
      CredentialSessionDomain.unified,
    );
    if (!durable.active) return null;
    if (durable.account?.trim() != account) return null;
    return durable;
  }

  /// 显式内存写入（对外 API 保持）：必须有明确 CAS owner；磁盘写入统一走
  /// 带持久 epoch 守卫的抓取路径。仅当已有当前有效持久 epoch 时可见。
  void updateCachedBalance(double? balance) {
    final owner = _currentAccount;
    if (balance == null || owner == null) return;
    _cachedBalance = balance;
    _lastUpdated = DateTime.now();
    _cachedOwner = owner;
    _cachedEpoch = _validEpoch;
    CampusDataChangeBus.instance.notifyChanged();
  }

  double? clearCachedBalance() {
    _clearMemoryCache();
    unawaited(_clearStoredBalance());
    return null;
  }

  Future<void> _clearStoredBalance() async {
    try {
      await _store.clear();
    } catch (_) {}
  }

  /// 明确清理：只允许清理该请求捕获的 owner / epoch / generation；旧请求的
  /// 失效错误不得清掉新账号余额。
  Future<double?> _clearCachedBalanceIfCurrent(_BalanceRequest request) async {
    if (!_isRequestCurrent(request)) return null;
    final cleared = await AuthSessionPersistence.instance
        .withCurrentSession<bool>(
          CredentialSessionDomain.unified,
          account: request.guard.account,
          expectedEpoch: request.guard.durableEpoch,
          action: () async {
            // 锁内仅本地 cache IO，不反调 auth / 不发网络。
            if (request.generation != _latestGeneration) return false;
            await _store.clear();
            return true;
          },
        );
    if (cleared != true) return null;
    if (!_isRequestCurrent(request)) return null;
    _clearMemoryCache();
    return null;
  }

  /// 冷恢复余额缓存：必须有明确 CAS 账号，且磁盘归属与**当前持久 epoch**
  /// 一致；旧无 epoch 记录安全舍弃，下次抓取重新写入。
  ///
  /// 读 + 采纳都在统一认证同域锁内、且当前会话仍是该账号该 epoch 时执行；
  /// 锁内只做本地 cache IO 与本地字段校验，不反调 auth / 不发网络。
  Future<void> restoreBalance() async {
    await _cleanupLegacyBalance();

    final current = _currentAccount;
    if (current == null) return;

    // 在 await 之前固定身份修订号 / 身份世代 / generation：读取期间同账号
    // 重登可能只 notify 不升 revision，迟到的读取 / 空结果不得覆盖新身份字段。
    final revisionAtRead = _authRevision;
    final identityEpochAtRead = _identityEpoch;
    final generationAtRead = _latestGeneration;
    final durable = await _readDurableSession(current);
    await debugDurableReadBarrier?.call();
    if (durable == null) {
      _failClosedAuthRequired(
        account: current,
        revision: revisionAtRead,
        identityEpoch: identityEpochAtRead,
        generation: generationAtRead,
      );
      return;
    }
    if (!_canAdoptDurableRead(
      account: current,
      revision: revisionAtRead,
      identityEpoch: identityEpochAtRead,
      durableEpoch: durable.epoch,
    )) {
      return;
    }
    final capturedEpoch = durable.epoch;
    _observeDurableEpoch(capturedEpoch);
    final capturedRevision = _authRevision;
    final capturedGeneration = _latestGeneration;

    // 测试注入点：可在获取同域锁之前推进持久 epoch，验证 restore 竞态。
    await debugRestoreBarrier?.call();

    await AuthSessionPersistence.instance.withCurrentSession<bool>(
      CredentialSessionDomain.unified,
      account: current,
      expectedEpoch: capturedEpoch,
      action: () async {
        if (_currentAccount != current) return false;
        if (_authRevision != capturedRevision) return false;
        if (_latestGeneration != capturedGeneration) return false;

        final envelope = await _store.read();
        if (envelope == null) return false;
        if (!envelope.belongsTo(current, capturedEpoch)) return false;

        final balance = _decodeBalance(envelope.payload);
        if (balance == null) return false;

        _cachedBalance = balance;
        _cachedOwner = current;
        _cachedEpoch = capturedEpoch;
        _validEpoch = capturedEpoch;
        _lastUpdated = envelope.updatedAt;
        return true;
      },
    );
  }

  /// 旧多 key 格式无法证明属于哪个持久身份纪元，直接清掉，下次刷新。
  Future<void> _cleanupLegacyBalance() async {
    final legacyBalance = await _storage.read(key: _legacyBalanceKey);
    final legacyOwner = await _storage.read(key: _legacyOwnerKey);
    final legacyUpdatedAt = await _storage.read(key: _legacyUpdatedAtKey);
    if (legacyBalance == null &&
        legacyOwner == null &&
        legacyUpdatedAt == null) {
      return;
    }
    await _storage.delete(key: _legacyBalanceKey);
    await _storage.delete(key: _legacyOwnerKey);
    await _storage.delete(key: _legacyUpdatedAtKey);
  }

  Future<double?> fetchBalance({bool forceRefresh = false}) async {
    final owner = _currentAccount;
    // 没有明确 CAS owner：零请求、不读不写任何 owner 数据；失败状态由
    // [lastBalanceFailure] 按当前身份派生出 authRequired。
    if (owner == null) return null;

    // 请求开始即固定持久身份（active + 账号 + epoch）与身份世代：读取期间
    // 身份 / 纪元变化时，迟到的读取结果一律不得采纳。
    final revisionAtRead = _authRevision;
    final identityEpochAtRead = _identityEpoch;
    final generationAtRead = _latestGeneration;
    final durable = await _readDurableSession(owner);
    await debugDurableReadBarrier?.call();
    if (durable == null) {
      // 持久身份缺失 / 不匹配：仅对捕获身份 fail-closed 清当前内存缓存与
      // valid epoch、作废在途请求；不删磁盘缓存、不全局登出。
      _failClosedAuthRequired(
        account: owner,
        revision: revisionAtRead,
        identityEpoch: identityEpochAtRead,
        generation: generationAtRead,
      );
      return null;
    }
    if (!_canAdoptDurableRead(
      account: owner,
      revision: revisionAtRead,
      identityEpoch: identityEpochAtRead,
      durableEpoch: durable.epoch,
    )) {
      return null;
    }
    _observeDurableEpoch(durable.epoch);
    final guard = _BalanceGuard(
      account: owner,
      revision: _authRevision,
      durableEpoch: durable.epoch,
    );

    if (!forceRefresh) {
      final cached = _readFreshCache(guard);
      if (cached != null) return cached;
    }

    final existing = _inFlight;
    if (existing != null && _isRequestCurrent(existing.request)) {
      // 同一最新请求直接共享（账号 / revision / generation / 已观测 epoch
      // 全部一致）；force 不被较旧的非 force 请求短路。
      if (!forceRefresh || existing.request.force) return existing.future;
    }

    final generation = ++_latestGeneration;
    final request = _BalanceRequest(
      guard: guard,
      generation: generation,
      force: forceRefresh,
    );
    final future = _fetchBalanceRemote(request);
    final inFlight = _BalanceInFlight(request: request, future: future);
    _inFlight = inFlight;
    return future.whenComplete(() {
      if (identical(_inFlight, inFlight)) _inFlight = null;
    });
  }

  double? _readFreshCache(_BalanceGuard guard) {
    final balance = _cachedBalance;
    if (balance == null) return null;
    if (_cachedOwner != guard.account) return null;
    if (_cachedEpoch != guard.durableEpoch) return null;
    if (guard.revision != _authRevision) return null;
    if (isStale) return null;
    return balance;
  }

  Future<double?> _fetchBalanceRemote(_BalanceRequest request) async {
    final testFetcher = debugBalanceFetcher;
    if (testFetcher != null) {
      try {
        final balance = await testFetcher();
        if (balance == null) return null;
        if (!_isRequestCurrent(request)) return null;
        final committed = await _commitBalance(request, balance);
        if (committed) {
          _lastBalanceFailure = BalanceFailureKind.none;
          return balance;
        }
        return null;
      } on EpaySessionUnavailableException {
        _recordBalanceFailure(request, BalanceFailureKind.authExpired);
        return _clearCachedBalanceIfCurrent(request);
      } on EpayGatewayException catch (error, stackTrace) {
        _recordBalanceFailure(request, BalanceFailureKind.serviceUnavailable);
        AppLogger.instance.network(
          LogLevel.warn,
          '校园卡余额刷新失败，保留上次余额',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      } catch (error, stackTrace) {
        _recordBalanceFailure(request, BalanceFailureKind.network);
        AppLogger.instance.network(
          LogLevel.warn,
          '校园卡余额刷新失败，保留上次余额',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }

    try {
      final balance = await _fetchBalanceFromGateway();
      if (balance != null) {
        final committed = await _commitBalance(request, balance);
        if (!committed) return null;
        _lastBalanceFailure = BalanceFailureKind.none;
        AppLogger.instance.network(LogLevel.info, '校园卡余额查询成功');
      } else {
        AppLogger.instance.network(LogLevel.warn, '校园卡余额响应缺少余额字段');
      }
      return balance;
    } on EpaySessionUnavailableException {
      _recordBalanceFailure(request, BalanceFailureKind.authExpired);
      // 明确会话失效：只在该请求仍是当前 owner / epoch / generation 时清理。
      return _clearCachedBalanceIfCurrent(request);
    } on EpayGatewayException catch (error, stackTrace) {
      _recordBalanceFailure(request, BalanceFailureKind.serviceUnavailable);
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额刷新失败，保留上次余额',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } catch (error, stackTrace) {
      _recordBalanceFailure(request, BalanceFailureKind.network);
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额刷新失败，保留上次余额',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 锁内（持久 epoch 校验通过）落盘，锁外再更新内存；写后内存身份 /
  /// generation 变化则不 notify、不覆盖 memory。
  Future<bool> _commitBalance(_BalanceRequest request, double balance) async {
    final account = request.guard.account;
    final now = DateTime.now();
    final committed = await AuthSessionPersistence.instance
        .withCurrentSession<bool>(
          CredentialSessionDomain.unified,
          account: account,
          expectedEpoch: request.guard.durableEpoch,
          action: () async {
            // 锁内仅本地 cache IO，不反调 auth / 不发网络。
            if (request.generation != _latestGeneration) return false;
            await _store.write(
              PrivateCacheEnvelope(
                owner: account,
                updatedAt: now,
                epoch: request.guard.durableEpoch,
                payload: balance,
              ),
            );
            return true;
          },
        );
    if (committed != true) return false;
    if (!_isRequestCurrent(request)) return false;
    _cachedBalance = balance;
    _lastUpdated = now;
    _cachedOwner = account;
    _cachedEpoch = request.guard.durableEpoch;
    _validEpoch = request.guard.durableEpoch;
    CampusDataChangeBus.instance.notifyChanged();
    return true;
  }

  /// 请求是否仍是当前上下文：账号 / revision / generation / 已观测 durable
  /// epoch 必须全部一致。任一项变化（登出、换号、同账号重登、跨 isolate
  /// 纪元更换、持久身份 fail-closed）都视为不能再复用 / 采纳其结果。
  bool _isRequestCurrent(_BalanceRequest request) {
    if (request.generation != _latestGeneration) return false;
    if (request.guard.revision != _authRevision) return false;
    if (request.guard.account != _currentAccount) return false;
    if (request.guard.durableEpoch != _validEpoch) return false;
    return true;
  }

  /// 仅当请求仍是当前 owner / revision / generation / 已观测 epoch 时才记录
  /// 失败：登出 / 换号 / 纪元更换后迟到的失败不得覆盖新身份的失败状态。
  void _recordBalanceFailure(_BalanceRequest request, BalanceFailureKind kind) {
    if (!_isRequestCurrent(request)) return;
    _lastBalanceFailure = kind;
  }

  /// 余额经共享 [Epay100Gateway]（与电费、付款码同一隐藏会话）在 epay100
  /// 页面上下文发 RPC：会话不可用抛 [EpaySessionUnavailableException]，
  /// 门户未绑定抛 [EpayBindingRequiredException]。
  Future<double?> _fetchBalanceFromGateway() async {
    final body = await _gateway.call(_balanceMethod, const {});
    final data = _decodeEpayData(body);
    final raw = data['balance'];
    if (raw == null) return null;
    return double.tryParse(raw.toString());
  }

  /// 解析 RPC 响应信封 `{"code":"200","msg":"...","data":{...}}`。
  Map<String, dynamic> _decodeEpayData(String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const EpayGatewayException('一卡通余额数据无法识别');
    }
    if (json is! Map<String, dynamic>) {
      throw const EpayGatewayException('一卡通余额数据格式异常');
    }
    if (json['code']?.toString() != '200') {
      final message = json['msg']?.toString() ?? '';
      throw EpayGatewayException(message.isEmpty ? '一卡通余额获取失败' : message);
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw const EpayGatewayException('一卡通余额数据为空');
    }
    return data;
  }

  static double? _decodeBalance(Object? payload) {
    if (payload is num) return payload.toDouble();
    if (payload is String) return double.tryParse(payload);
    return null;
  }

  /// 交互页面（账单）经移动大厅网关：目标 CAS 会话及 URL 选择。
  Future<String> prepareStatusPage() async {
    await DioClient.instance.ensureInitialized();
    await UnifiedAuthService.instance.restoreSession(syncWebViewCookies: false);
    if (!UnifiedAuthService.instance.isLoggedIn) {
      throw const CasAuthExpiredException();
    }
    final gateway = await ZhengfangAuth.instance
        .ensureWebVpnGatewaySessionResult(
          syncWebViewCookies: true,
          targetUrl: statusPageUrl,
        );
    if (gateway.ready == false) throw const CasAuthExpiredException();
    if (gateway.ready == null) throw TimeoutException('校园卡网关暂时无法连接');

    final sessionStatus = await CasSession.ensure(
      CasService.campusCardStatus.serviceUrl,
      syncWebViewCookies: false,
    );
    if (sessionStatus == CasSessionStatus.inactive) {
      throw const CasAuthExpiredException();
    }
    if (sessionStatus == CasSessionStatus.unknown) {
      throw TimeoutException('校园卡认证暂时无法连接');
    }
    await UnifiedAuthService.instance.syncCookiesToWebViewForUrl(statusPageUrl);
    return gateway.selectedMode == ZhengfangMode.webVpn
        ? ZhengfangAuth.instance.buildWebVpnProxyUrl(statusPageUrl)
        : statusPageUrl;
  }

  String formatBalance(double? balance) {
    if (balance == null) return '--';

    if (balance == balance.truncateToDouble()) {
      return balance.toStringAsFixed(0);
    }

    return balance
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  /// 测试注入：owner 取自当前明确 CAS 账号；无账号时为 null（不可见）。
  /// epoch 采用当前已知有效 epoch（未读取过 durable 时为 null → 不可见）。
  @visibleForTesting
  void debugSetCachedBalance(double? balance, {DateTime? updatedAt}) {
    _cachedBalance = balance;
    _lastUpdated = updatedAt;
    _cachedOwner = balance == null ? null : _currentAccount;
    _cachedEpoch = _validEpoch;
  }

  @visibleForTesting
  void debugSetLastBalanceFailure(BalanceFailureKind kind) {
    _lastBalanceFailure = kind;
  }

  /// 测试注入：直接触发统一认证 identity 通知处理（模拟同账号重登时
  /// `sessionRevision` 不增、只有通知的路径）。
  @visibleForTesting
  void debugHandleUnifiedAuthChanged() => _onUnifiedAuthChanged();

  /// 当前可见的账单快照缓存：归属校验只看 owner（为 null 或与当前 CAS
  /// 账号不一致即不可见，fail closed）。纯内存缓存不写盘，身份变化时
  /// [_onUnifiedAuthChanged] 已整体清掉并作废在途请求，无需 durable
  /// epoch 参与可见性；跨 isolate 纪元漂移风险由 [fetchConsumption] 采
  /// 纳侧的 epoch 守卫覆盖。
  CampusCardConsumptionSummary? get cachedConsumption {
    final summary = _cachedConsumption;
    if (summary == null) return null;
    final owner = _cachedConsumptionOwner;
    if (owner == null || owner != _currentAccount) return null;
    return summary;
  }

  /// 缓存是否已过 [consumptionRefreshWindow]；无缓存视为过期。
  bool get consumptionCacheIsStale {
    if (_cachedConsumption == null) return true;
    final updatedAt = _consumptionUpdatedAt;
    if (updatedAt == null) return true;
    return DateTime.now().difference(updatedAt) >= consumptionRefreshWindow;
  }

  /// 校园卡主页内嵌预览用的最近几条真实消费；没有快照时返回 null。
  List<CampusCardConsumptionEntry>? get cachedConsumptionPreview {
    final summary = cachedConsumption;
    if (summary == null) return null;
    return summary.recent
        .take(consumptionPreviewLimit)
        .toList(growable: false);
  }

  /// 抓一次账单快照（四格统计 + 近期消费 + 三餐 / 单日统计）。
  ///
  /// 无明确 CAS owner / 持久身份时不发起查询、返回 null（页面按认证状态渲染）；
  /// 网关 / 网络 / 会话失败同样返回 null，由页面给出「重试 + H5 兜底」——
  /// 失败不清已有缓存，也不升格为登录问题。
  ///
  /// [forceRefresh] 为 false 时命中未过期缓存直接返回，不触网。请求完成后校验
  /// 捕获的 owner / revision / durable epoch / fetch 序号仍是当前身份上下文才
  /// 采纳；登出 / 换号 / 新一次请求已发出时旧结果一律丢弃（页面再读缓存看到
  /// 空态，而不是旧账号流水）。
  Future<CampusCardConsumptionSummary?> fetchConsumption({
    bool forceRefresh = false,
  }) async {
    final owner = _currentAccount;
    if (owner == null) return null;
    if (!forceRefresh) {
      final cached = cachedConsumption;
      if (cached != null && !consumptionCacheIsStale) return cached;
    }

    final revisionAtRead = _authRevision;
    final durable = await _readDurableSession(owner);
    if (durable == null) return null;
    _observeDurableEpoch(durable.epoch);
    final fetchId = ++_latestConsumptionFetch;

    try {
      final summary = await (debugConsumptionFetcher ??
          fetchConsumptionRemote)();
      if (summary == null) return null;
      if (_latestConsumptionFetch != fetchId) return null;
      if (_currentAccount != owner) return null;
      if (_authRevision != revisionAtRead) return null;
      if (_validEpoch != durable.epoch) return null;
      _cachedConsumption = summary;
      _cachedConsumptionOwner = owner;
      _consumptionUpdatedAt = DateTime.now();
      return summary;
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡账单获取失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 网关抓取 + 解析：`CampusCardBillGateway` 负责页面上下文取数，
  /// [CampusCardConsumptionSummary.parse] 做纯函数解析。
  Future<CampusCardConsumptionSummary> fetchConsumptionRemote() async {
    final raw = await (debugBillRawFetcher ??
        CampusCardBillGateway.instance.fetch)();
    return CampusCardConsumptionSummary.parse(raw);
  }

  /// 丢弃账单页网关会话（登录态变化 / 手动重试连不上时调用）。
  Future<void> invalidateBillGateway() =>
      CampusCardBillGateway.instance.invalidate();

  // ── 遗留：渠道充值流水（`app.portal.getBillList`）───────────────────────
  // 不是真实消费，勿用作账单数据源。保留仅为尚未切换的内嵌区块编译。

  /// 当前可见的旧预览缓存：归属校验只看 owner（fail closed）。
  List<CampusCardBillEntry>? get cachedBillEntries {
    final entries = _cachedBillEntries;
    if (entries == null) return null;
    final owner = _cachedBillOwner;
    if (owner == null || owner != _currentAccount) return null;
    return entries;
  }

  /// 旧预览缓存是否已过期；无缓存视为过期。
  bool get billCacheIsStale {
    if (_cachedBillEntries == null) return true;
    final updatedAt = _billUpdatedAt;
    if (updatedAt == null) return true;
    return DateTime.now().difference(updatedAt) >= billRefreshWindow;
  }

  /// 旧「最近账单」预览：取最近 [billPreviewDays] 天充值流水，截
  /// [billPreviewLimit] 条。身份 / 网关失败一律返回 null。
  Future<List<CampusCardBillEntry>?> fetchBillPreview({
    bool forceRefresh = false,
  }) async {
    final owner = _currentAccount;
    if (owner == null) return null;
    if (!forceRefresh) {
      final cached = cachedBillEntries;
      if (cached != null && !billCacheIsStale) return cached;
    }

    final revisionAtRead = _authRevision;
    final durable = await _readDurableSession(owner);
    if (durable == null) return null;
    _observeDurableEpoch(durable.epoch);
    final fetchId = ++_latestBillFetch;

    try {
      final now = DateTime.now();
      final entries =
          await (debugBillFetcher ??
              () => fetchBillList(
                start: now.subtract(const Duration(days: billPreviewDays)),
                end: now,
              ))();
      if (_latestBillFetch != fetchId) return null;
      if (_currentAccount != owner) return null;
      if (_authRevision != revisionAtRead) return null;
      if (_validEpoch != durable.epoch) return null;
      final preview = entries.take(billPreviewLimit).toList(growable: false);
      _cachedBillEntries = preview;
      _cachedBillOwner = owner;
      _billUpdatedAt = DateTime.now();
      return preview;
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡账单预览获取失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 旧充值流水：经共享 [Epay100Gateway] 发 `app.portal.getBillList`
  /// （入参 `startDate`/`endDate`，`yyyyMMdd`，间隔 ≤31 天）。
  Future<List<CampusCardBillEntry>> fetchBillList({
    required DateTime start,
    required DateTime end,
  }) async {
    final body = await _gateway.call('app.portal.getBillList', {
      'startDate': _fmtBillDate(start),
      'endDate': _fmtBillDate(end),
    });
    final data = _decodeEpayData(body);
    final list = data['data'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) CampusCardBillEntry.fromJson(item),
    ];
  }

  static String _fmtBillDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  @visibleForTesting
  void debugReset() {
    _clearMemoryCache();
    _validEpoch = null;
    _inFlight = null;
    _latestGeneration = 0;
    _identityEpoch = 0;
    _lastBalanceFailure = BalanceFailureKind.none;
    debugRestoreBarrier = null;
    debugDurableReadBarrier = null;
    debugBalanceFetcher = null;
    debugConsumptionFetcher = null;
    debugBillRawFetcher = null;
    debugBillFetcher = null;
    debugGateway = null;
  }
}

/// 一次抓取开始时固定的 CAS 身份与持久纪元。
class _BalanceGuard {
  const _BalanceGuard({
    required this.account,
    required this.revision,
    required this.durableEpoch,
  });

  final String account;
  final int revision;
  final int durableEpoch;
}

/// 单个余额请求：owner/epoch/revision guard + 同 key generation。
class _BalanceRequest {
  const _BalanceRequest({
    required this.guard,
    required this.generation,
    required this.force,
  });

  final _BalanceGuard guard;
  final int generation;
  final bool force;
}

class _BalanceInFlight {
  const _BalanceInFlight({required this.request, required this.future});

  final _BalanceRequest request;
  final Future<double?> future;
}
