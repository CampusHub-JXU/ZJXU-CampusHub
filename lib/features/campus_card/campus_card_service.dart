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

enum BalanceFailureKind { none, authExpired, serviceUnavailable, network }

class CampusCardService {
  CampusCardService._() {
    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
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

  double? _cachedBalance;
  DateTime? _lastUpdated;
  String? _cachedOwner;
  int? _cachedEpoch;
  BalanceFailureKind _lastBalanceFailure = BalanceFailureKind.none;

  /// 当前有效的持久身份纪元（最近一次读到 durable session 的 epoch）。
  int? _validEpoch;

  _BalanceInFlight? _inFlight;
  int _latestGeneration = 0;

  /// 测试注入：restore 读取持久 epoch 之后、获取同域锁之前的屏障。
  @visibleForTesting
  Future<void> Function()? debugRestoreBarrier;

  /// 统一认证身份修订号：登录 / 登出 / 换号 / 恢复时递增，异步期间发生
  /// 变化的旧结果一律丢弃。仅进程内有效。
  int get _authRevision => UnifiedAuthService.instance.sessionRevision;

  @visibleForTesting
  Future<double?> Function()? debugBalanceFetcher;

  @visibleForTesting
  Epay100Gateway? debugGateway;

  Epay100Gateway get _gateway => debugGateway ?? Epay100Gateway.instance;

  /// 必须已登录且账号非空；否则视为没有明确 CAS owner。
  String? get _currentAccount {
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn) return null;
    final account = auth.currentAccount?.trim();
    return (account == null || account.isEmpty) ? null : account;
  }

  /// 统一认证只在身份变化时 notify；直接清空内存缓存，getter 另有归属
  /// 校验兜底。
  void _onUnifiedAuthChanged() {
    _clearMemoryCache();
    _validEpoch = null;
    _lastBalanceFailure = BalanceFailureKind.none;
  }

  void _clearMemoryCache() {
    _cachedBalance = null;
    _lastUpdated = null;
    _cachedOwner = null;
    _cachedEpoch = null;
  }

  /// 记录当前 durable epoch；与已采纳记录 epoch 不一致即失效内存缓存。
  void _observeDurableEpoch(int epoch) {
    if (_cachedEpoch != null && _cachedEpoch != epoch) {
      _clearMemoryCache();
    }
    _validEpoch = epoch;
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

  DateTime? get updatedAt => _lastUpdated;

  BalanceFailureKind get lastBalanceFailure => _lastBalanceFailure;

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

    final durable = await _readDurableSession(current);
    if (durable == null) return;
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
    // 没有明确 CAS owner：零请求、不读不写任何 owner 数据。
    if (owner == null) return null;

    // 请求开始即固定持久身份（active + 账号 + epoch）。
    final durable = await _readDurableSession(owner);
    if (durable == null) return null;
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
    if (existing != null && existing.request.generation == _latestGeneration) {
      // 同一最新请求直接共享；force 不被较旧的非 force 请求短路。
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
        _lastBalanceFailure = BalanceFailureKind.authExpired;
        return _clearCachedBalanceIfCurrent(request);
      } on EpayGatewayException catch (error, stackTrace) {
        _lastBalanceFailure = BalanceFailureKind.serviceUnavailable;
        AppLogger.instance.network(
          LogLevel.warn,
          '校园卡余额刷新失败，保留上次余额',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      } catch (error, stackTrace) {
        _lastBalanceFailure = BalanceFailureKind.network;
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
      _lastBalanceFailure = BalanceFailureKind.authExpired;
      // 明确会话失效：只在该请求仍是当前 owner / epoch / generation 时清理。
      return _clearCachedBalanceIfCurrent(request);
    } on EpayGatewayException catch (error, stackTrace) {
      _lastBalanceFailure = BalanceFailureKind.serviceUnavailable;
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额刷新失败，保留上次余额',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } catch (error, stackTrace) {
      _lastBalanceFailure = BalanceFailureKind.network;
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

  bool _isRequestCurrent(_BalanceRequest request) {
    if (request.generation != _latestGeneration) return false;
    if (request.guard.revision != _authRevision) return false;
    return request.guard.account == _currentAccount;
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

  @visibleForTesting
  void debugReset() {
    _clearMemoryCache();
    _validEpoch = null;
    _inFlight = null;
    _latestGeneration = 0;
    _lastBalanceFailure = BalanceFailureKind.none;
    debugRestoreBarrier = null;
    debugBalanceFetcher = null;
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
