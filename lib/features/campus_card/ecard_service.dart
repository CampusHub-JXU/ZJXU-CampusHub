import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import '../../core/auth/login_page_detection.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';

class EcardService {
  EcardService._();
  static final EcardService instance = EcardService._();

  static const _baseUrl = 'http://ecard.zjxu.edu.cn:8012';
  static const _directTimeout = Duration(seconds: 3);
  static const _secretKey = 'ok15we1@oid8x5afd@';

  String? _cachedAccName;

  @visibleForTesting
  static String formatTime(DateTime now) {
    return '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
  }

  @visibleForTesting
  static String md5Hash(String input) {
    final digest = MD5Digest();
    final data = Uint8List.fromList(utf8.encode(input));
    final output = Uint8List(digest.digestSize);
    digest.update(data, 0, data.length);
    digest.doFinal(output, 0);
    return output.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @visibleForTesting
  static String generateSign(List<String> values) {
    final joined = values.join('|');
    return md5Hash('$joined|$_secretKey');
  }

  Map<String, String> _buildParams(Map<String, String> signParams) {
    final time = formatTime(DateTime.now());
    final sortedKeys = signParams.keys.toList()..sort();
    final sortedValues = sortedKeys.map((k) => signParams[k]!).toList();
    sortedValues.add(time);
    final sign = generateSign(sortedValues);
    return {...signParams, 'Time': time, 'Sign': sign, 'ContentType': 'json'};
  }

  static const connectionFailureMessage = '旧版服务连接失败，请检查网络或使用官方付款页';
  static const _webVpnUnavailableMessage = '旧版服务直连失败，暂时无法确认 WebVPN 会话，请稍后重试';
  static const _webVpnLoginRequiredMessage = '旧版服务直连失败，WebVPN 未登录，请重新登录一卡通';

  Future<String?> _post(
    String path,
    Map<String, String> params,
    _EcardOperation operation,
  ) async {
    if (!operation.isCurrent) return null;
    final client = DioClient.instance;
    await client.ensureInitialized();
    if (!operation.isCurrent) return null;

    final directUrl = '$_baseUrl$path';
    // 同一 operation 内直连已失败过则不再尝试（校外时白等 _directTimeout），
    // 直接进入 WebVPN 分支；缓存只随 operation 生命周期，不做 service 级持久化。
    if (!operation.webVpnReady) {
      try {
        final response = await client.dio.post<String>(
          directUrl,
          data: params,
          options: Options(
            connectTimeout: _directTimeout,
            sendTimeout: _directTimeout,
            receiveTimeout: _directTimeout,
            contentType: 'application/x-www-form-urlencoded',
            responseType: ResponseType.plain,
            headers: {'Referer': '$_baseUrl/index.html', 'Origin': _baseUrl},
          ),
        );
        return operation.isCurrent ? response.data ?? '' : null;
      } on DioException catch (error) {
        if (!_isConnectionFailure(error)) rethrow;
        if (!operation.isCurrent) return null;
        operation.webVpnReady = true;
        AppLogger.instance.network(
          LogLevel.info,
          'ecard $path 直连失败（${error.type.name}），尝试 WebVPN',
        );
      }
    }

    final auth = ZhengfangAuth.instance;
    if (!operation.webVpnReady || !auth.isWebVpnLoggedIn) {
      // 普通 ensure 允许直连探测成功时直接返回 true，无法证明网关会话就绪。
      final session = await auth.ensureWebVpnGatewaySessionResult(
        targetUrl: _baseUrl,
        forceWebVpn: true,
        syncWebViewCookies: false,
      );
      if (!operation.isCurrent) return null;
      switch (session.ready) {
        case false:
          throw const EcardConnectionException(_webVpnLoginRequiredMessage);
        case null:
          throw const EcardConnectionException(_webVpnUnavailableMessage);
        case true:
          operation.webVpnReady = true;
      }
    }

    final proxyUrl = auth.buildWebVpnProxyUrl(directUrl);
    if (proxyUrl == directUrl) {
      const message = '旧版服务未配置 WebVPN 代理地址';
      AppLogger.instance.network(LogLevel.warn, 'ecard $path $message');
      throw const EcardConnectionException(message);
    }

    if (!operation.isCurrent) return null;
    final response = await _postViaWebVpn(path, proxyUrl, params);
    if (!operation.isCurrent) return null;
    final body = response.data ?? '';
    final uri = response.requestOptions.uri;
    final status = response.statusCode;
    final location = response.headers.value('location');
    final redirect = location == null ? null : Uri.tryParse(location);
    final redirectedToPortal =
        status != null &&
        status >= 300 &&
        status < 400 &&
        redirect != null &&
        isWebVpnPortalUrl(uri.resolveUri(redirect).toString());
    if (classifyLoginExchange(
              realUrl: response.realUri.toString(),
              statusCode: status,
              location: redirect?.toString(),
              requestUri: uri,
              html: body.trimLeft().startsWith('<') ? body : null,
              kinds: casAndGatewayLoginKinds,
            ) !=
            null ||
        redirectedToPortal) {
      AppLogger.instance.network(LogLevel.warn, 'ecard $path WebVPN 会话已失效');
      throw const EcardConnectionException('WebVPN 会话已失效，请重新登录一卡通');
    }
    if (status == null || status < 200 || status >= 300) {
      final message = '旧版服务 WebVPN 请求失败（HTTP ${status ?? '未知'}）';
      AppLogger.instance.network(LogLevel.warn, 'ecard $path $message');
      throw EcardConnectionException(message);
    }
    return body;
  }

  Future<Response<String>> _postViaWebVpn(
    String path,
    String proxyUrl,
    Map<String, String> params,
  ) async {
    try {
      return await DioClient.instance.unifiedAuthDio.post<String>(
        proxyUrl,
        data: params,
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null,
          headers: {
            'Referer': ZhengfangAuth.instance.buildWebVpnProxyUrl(
              '$_baseUrl/index.html',
            ),
            'Origin': Uri.parse(proxyUrl).origin,
          },
        ),
      );
    } on DioException catch (error) {
      final message = '$connectionFailureMessage（WebVPN ${error.type.name}）';
      AppLogger.instance.network(LogLevel.warn, 'ecard $path $message');
      throw EcardConnectionException(message);
    }
  }

  static bool _isConnectionFailure(DioException error) {
    DioException current = error;
    for (var i = 0; i < 3; i++) {
      if (current.response != null) return false;
      switch (current.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.unknown:
          final nested = current.error;
          if (nested is DioException) {
            current = nested;
            continue;
          }
          final text = current.message ?? nested?.toString() ?? '';
          return text.contains('Connection reset') ||
              text.contains('Connection refused') ||
              text.contains('SocketException');
        default:
          return false;
      }
    }
    return false;
  }

  static String studentIdToAccNum(String studentId) {
    return studentId.replaceFirst(RegExp(r'^0+'), '');
  }

  Future<bool> queryAccAuth(String accNum) =>
      _queryAccAuth(accNum, _EcardOperation());

  Future<bool> _queryAccAuth(String accNum, _EcardOperation operation) async {
    try {
      final params = _buildParams({'AccNum': accNum});
      final body = await _post('/QueryAccAuth.aspx', params, operation);
      if (body == null) return false;
      final json = _tryParseJson(body);
      if (json?['Code']?.toString() == '1') {
        AppLogger.instance.network(LogLevel.info, 'ecard 认证成功');
        return true;
      }
      AppLogger.instance.network(
        LogLevel.warn,
        'ecard 认证失败: ${json?['Msg'] ?? '响应格式异常'}',
      );
      return false;
    } on EcardConnectionException {
      rethrow;
    } catch (e) {
      AppLogger.instance.network(LogLevel.error, 'ecard 认证异常: $e');
      return false;
    }
  }

  Future<String?> getAccInfo(String accNum) =>
      _getAccInfo(accNum, _EcardOperation());

  Future<String?> _getAccInfo(String accNum, _EcardOperation operation) async {
    try {
      final params = _buildParams({'AccNum': accNum});
      final body = await _post('/QueryAccInfoH.aspx', params, operation);
      if (body == null || !operation.isCurrent) return null;
      final json = _tryParseJson(body);
      if (json != null && json['Code']?.toString() == '1') {
        final accName = json['AccName'] as String? ?? '';
        _cachedAccName = accName;
        return accName;
      }
      return null;
    } on EcardConnectionException {
      rethrow;
    } catch (e) {
      AppLogger.instance.network(LogLevel.error, 'ecard 账户信息查询异常: $e');
      return null;
    }
  }

  Future<String?> getQRCode(String accNum, {bool Function()? shouldContinue}) =>
      _getQRCode(accNum, _EcardOperation(shouldContinue));

  Future<String?> _getQRCode(String accNum, _EcardOperation operation) async {
    try {
      final params = _buildParams({'AccNum': accNum});
      final body = await _post('/GetQRCode.aspx', params, operation);
      if (body == null || !operation.isCurrent) return null;
      final json = _tryParseJson(body);
      if (json != null && json['Code']?.toString() == '1') {
        final qrCode = json['QRCode'] as String? ?? '';
        if (qrCode.isNotEmpty) {
          AppLogger.instance.network(LogLevel.info, 'ecard 二维码获取成功');
          return qrCode;
        }
      }
      final msg = json?['Msg'] as String? ?? '未知错误';
      AppLogger.instance.network(LogLevel.warn, 'ecard 二维码获取失败: $msg');
      return null;
    } on EcardConnectionException {
      rethrow;
    } catch (e) {
      AppLogger.instance.network(LogLevel.error, 'ecard 二维码获取异常: $e');
      return null;
    }
  }

  Future<QRCodeInfoResult> getQRCodeInfo(String qrCode) async {
    try {
      final params = _buildParams({'QRCode': qrCode});
      final body = await _post(
        '/GetQRCodeInfo.aspx',
        params,
        _EcardOperation(),
      );
      final json = body == null ? null : _tryParseJson(body);
      if (json != null) {
        if (AppLogger.instance.config.value.networkVerboseEnabled) {
          AppLogger.instance.network(LogLevel.debug, 'ecard QR状态响应: $json');
        }
        final code = json['Code']?.toString() ?? '';
        final msg = json['Msg'] as String? ?? '';
        final tradeAmt = json['TradeAmt'] as String? ?? '';
        final tradeState = json['TradeState'] as String? ?? '';
        return QRCodeInfoResult(
          code: code,
          msg: msg,
          tradeAmt: tradeAmt,
          tradeState: tradeState,
        );
      }
      return const QRCodeInfoResult(code: '', msg: '解析失败');
    } on EcardConnectionException catch (e) {
      AppLogger.instance.network(LogLevel.warn, 'ecard 二维码状态查询连接失败');
      return QRCodeInfoResult(code: '', msg: e.message);
    } catch (e) {
      AppLogger.instance.network(LogLevel.warn, 'ecard 二维码状态查询异常: $e');
      return QRCodeInfoResult(code: '', msg: e.toString());
    }
  }

  /// 认证 → 账户信息 → 取码的多步流程。
  ///
  /// [shouldContinue] 在直连、网关预热和代理请求的间隙检查；返回 false 时
  /// 丢弃在途结果并停止发送后续请求。缺省 null 保持既有行为。
  Future<QRCodeInitResult> initializeAndCreateQRCode(
    String studentId, {
    bool Function()? shouldContinue,
  }) async {
    final operation = _EcardOperation(shouldContinue);
    const aborted = QRCodeInitResult(error: '登录状态已变更，已取消本次取码');

    try {
      final accNum = studentIdToAccNum(studentId);
      final authOk = await _queryAccAuth(accNum, operation);
      if (!operation.isCurrent) return aborted;
      if (!authOk) {
        return QRCodeInitResult(error: '校园卡认证失败');
      }

      await _getAccInfo(accNum, operation);
      if (!operation.isCurrent) return aborted;

      final qrCode = await _getQRCode(accNum, operation);
      if (!operation.isCurrent) return aborted;
      if (qrCode == null) {
        return QRCodeInitResult(error: '获取消费码失败');
      }

      return QRCodeInitResult(
        accNum: accNum,
        accName: _cachedAccName,
        qrCode: qrCode,
      );
    } on EcardConnectionException catch (e) {
      if (!operation.isCurrent) return aborted;
      return QRCodeInitResult(error: e.message);
    }
  }

  void clearCache() {
    _cachedAccName = null;
  }

  Map<String, dynamic>? _tryParseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

class _EcardOperation {
  _EcardOperation([this.shouldContinue]);

  final bool Function()? shouldContinue;
  bool webVpnReady = false;

  bool get isCurrent => shouldContinue?.call() ?? true;
}

class EcardConnectionException implements Exception {
  const EcardConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class QRCodeInitResult {
  const QRCodeInitResult({this.accNum, this.accName, this.qrCode, this.error});

  final String? accNum;
  final String? accName;
  final String? qrCode;
  final String? error;

  bool get isSuccess => error == null && qrCode != null;
}

class QRCodeInfoResult {
  const QRCodeInfoResult({
    required this.code,
    this.msg = '',
    this.tradeAmt = '',
    this.tradeState = '',
  });

  final String code;
  final String msg;
  final String tradeAmt;
  final String tradeState;

  bool get isUsed => code == '1' && tradeAmt.isNotEmpty;
  bool get isPending => !isUsed;
}
