import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/epay100/epay100_gateway.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import '../../core/system_surface/campus_data_change_bus.dart';

class CampusCardService {
  CampusCardService._();

  static final CampusCardService instance = CampusCardService._();

  static const _storage = FlutterSecureStorage();
  static const _keyBalance = 'zjxu_campus_card_balance';

  /// 余额 RPC：epay100 `cardService/index` 页面取卡内余额所用 method，
  /// 无 data 参数，响应 `data.balance`。
  static const _balanceMethod = 'app.yktservice.getBalance';

  double? _cachedBalance;
  DateTime? _lastUpdated;
  Future<double?>? _balanceFetchFuture;

  @visibleForTesting
  Future<double?> Function()? debugBalanceFetcher;

  @visibleForTesting
  Epay100Gateway? debugGateway;

  Epay100Gateway get _gateway => debugGateway ?? Epay100Gateway.instance;

  double? get cachedBalance => _cachedBalance;
  DateTime? get lastUpdated => _lastUpdated;

  static const statusPageUrl =
      'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5&viewlet=xxkj%252Fmobile%252Fykt.frm#/form';

  /// CAS service URL — fragment (#/form) 不能包含在 service 参数里，
  /// 否则 ticket 验证时 service 不匹配导致认证失败。
  /// URL 注册表统一收敛在 [CasService]。
  static final statusPageCasServiceUrl = CasService.campusCardStatus.serviceUrl;

  void updateCachedBalance(double? balance) {
    if (balance == null) return;
    _cachedBalance = balance;
    _lastUpdated = DateTime.now();
    _storage.write(key: _keyBalance, value: balance.toString());
    CampusDataChangeBus.instance.notifyChanged();
  }

  double? clearCachedBalance() {
    _cachedBalance = null;
    _lastUpdated = null;
    unawaited(_storage.delete(key: _keyBalance));
    return null;
  }

  Future<void> restoreBalance() async {
    final stored = await _storage.read(key: _keyBalance);
    if (stored != null) {
      _cachedBalance = double.tryParse(stored);
    }
  }

  Future<double?> fetchBalance({bool forceRefresh = false}) {
    if (!forceRefresh && _cachedBalance != null) {
      return Future<double?>.value(_cachedBalance);
    }

    final existing = _balanceFetchFuture;
    if (existing != null) return existing;

    final future = _fetchBalanceRemote();
    _balanceFetchFuture = future;
    return future.whenComplete(() {
      if (identical(_balanceFetchFuture, future)) {
        _balanceFetchFuture = null;
      }
    });
  }

  Future<double?> _fetchBalanceRemote() async {
    final testFetcher = debugBalanceFetcher;
    if (testFetcher != null) {
      final balance = await testFetcher();
      if (balance != null) updateCachedBalance(balance);
      return balance;
    }

    try {
      final balance = await _fetchBalanceFromGateway();
      if (balance != null) {
        updateCachedBalance(balance);
        AppLogger.instance.network(LogLevel.info, '校园卡余额查询成功');
      } else {
        AppLogger.instance.network(LogLevel.warn, '校园卡余额响应缺少余额字段');
      }
      return balance;
    } on EpaySessionUnavailableException {
      return clearCachedBalance();
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额刷新失败，保留上次余额',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
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

  @visibleForTesting
  void debugSetCachedBalance(double? balance, {DateTime? updatedAt}) {
    _cachedBalance = balance;
    _lastUpdated = updatedAt;
  }

  @visibleForTesting
  void debugReset() {
    _cachedBalance = null;
    _lastUpdated = null;
    _balanceFetchFuture = null;
    debugBalanceFetcher = null;
    debugGateway = null;
  }
}
