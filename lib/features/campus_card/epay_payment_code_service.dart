import 'dart:convert';

import '../../core/epay100/epay100_gateway.dart';

/// 一卡通付款码：纯文本支付凭证 + 服务端建议的刷新间隔。
class EpayPaymentCode {
  const EpayPaymentCode({required this.qrcode, required this.refreshAfter});

  /// 纯文本支付凭证（qr_flutter 直接渲染；不落日志、不缓存、不持久化）。
  final String qrcode;

  /// 刷新间隔（基于服务端有效值保守截断，不超过 60 秒）。
  final Duration refreshAfter;
}

/// 一卡通付款码服务：经共享 [Epay100Gateway] 在 epay100 页面上下文发 RPC。
///
/// 每次调用都现取配置与付款码，不做持久缓存；二维码与响应原文不进日志。
/// 会话不可用抛 [EpaySessionUnavailableException]，门户需绑定抛
/// [EpayBindingRequiredException]，其它网关/业务失败抛 [EpayGatewayException]。
class EpayPaymentCodeService {
  EpayPaymentCodeService({Epay100Gateway? gateway})
    : _gateway = gateway ?? Epay100Gateway.instance;

  final Epay100Gateway _gateway;

  /// epay100 官方付款码页（与旧 CCB 付款码入口不同）。
  static const officialUrl =
      'https://www.epay100.cn/901/6279/cardService/PayCode';

  static const _defaultRefresh = Duration(seconds: 60);
  static const _maxRefresh = Duration(seconds: 60);

  /// 拉取付款码。先取配置（校验当前客户端是否被允许直接出码），再取码。
  Future<EpayPaymentCode> fetch() async {
    final refreshAfter = await _fetchConfig();

    final body = await _gateway.call('app.yktservice.getPayQrcode', const {
      'withhold_pay_type': 'pay_yktpay',
      'refresh': '1',
    });
    final data = _decodeDataMap(body);
    final qrcode = data['qrcode']?.toString() ?? '';
    if (qrcode.trim().isEmpty) {
      // 空码按失败处理；响应原文含支付凭证，不进异常信息、不进日志。
      throw const EpayGatewayException('付款码获取失败，请稍后重试');
    }
    return EpayPaymentCode(qrcode: qrcode, refreshAfter: refreshAfter);
  }

  static const _selectGuardMessage = '当前版本不支持选择付款账户，请前往官方付款码页面出示付款码';

  /// 配置解析（配置在 `data.mod_settings` 之下）：
  /// - 信封错误不吞；
  /// - 只有明确开启支付渠道选择时才指向官方页；缺失 `page_settings` 与官方
  ///   可选链行为一致，按未开启处理；
  /// - `basic_settings.paycode_refresh_time` 缺失或无效默认 60 秒；正数
  ///   尊重服务端值，上限 60 秒。
  Future<Duration> _fetchConfig() async {
    final body = await _gateway.call('app.yktservice.getSetting', const {});
    final data = _decodeDataMap(body);
    final mod = data['mod_settings'];
    if (mod is! Map<String, dynamic>) return _defaultRefresh;

    final pages = mod['page_settings'];
    final selectEnabled = pages is Map<String, dynamic>
        ? pages['pay_select_enabled']
        : null;
    if (_isTruthyConfigValue(selectEnabled)) {
      throw const EpayGatewayException(_selectGuardMessage);
    }

    final basic = mod['basic_settings'];
    if (basic is! Map<String, dynamic>) return _defaultRefresh;
    final seconds = int.tryParse(
      basic['paycode_refresh_time']?.toString() ?? '',
    );
    if (seconds == null || seconds <= 0) return _defaultRefresh;
    final capped = seconds > _maxRefresh.inSeconds
        ? _maxRefresh.inSeconds
        : seconds;
    return Duration(seconds: capped);
  }

  // Match the official JavaScript conditional while treating a missing field as false.
  static bool _isTruthyConfigValue(Object? value) {
    if (value == null || value == false) return false;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    return true;
  }

  /// 解析 RPC 响应信封 `{"code":"200","msg":"...","data":{...}}`。
  Map<String, dynamic> _decodeDataMap(String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const EpayGatewayException('付款码数据无法识别');
    }
    if (json is! Map<String, dynamic>) {
      throw const EpayGatewayException('付款码数据格式异常');
    }
    if (json['code']?.toString() != '200') {
      final message = json['msg']?.toString() ?? '';
      throw EpayGatewayException(message.isEmpty ? '付款码获取失败' : message);
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw const EpayGatewayException('付款码数据为空');
    }
    return data;
  }
}
