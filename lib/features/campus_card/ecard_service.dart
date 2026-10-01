import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';

class EcardService {
  EcardService._();
  static final EcardService instance = EcardService._();

  static const _baseUrl = 'http://ecard.zjxu.edu.cn:8012';
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

  Future<String> _post(String path, Map<String, String> params) async {
    await DioClient.instance.ensureInitialized();
    final dio = DioClient.instance.dio;
    try {
      final response = await dio.post<String>(
        '$_baseUrl$path',
        data: params,
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          responseType: ResponseType.plain,
          headers: {'Referer': '$_baseUrl/index.html', 'Origin': _baseUrl},
        ),
      );
      return response.data ?? '';
    } on DioException catch (error) {
      if (_isConnectionFailure(error)) {
        throw const EcardConnectionException(connectionFailureMessage);
      }
      rethrow;
    }
  }

  static bool _isConnectionFailure(DioException error) {
    DioException current = error;
    for (var i = 0; i < 3; i++) {
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

  Future<bool> queryAccAuth(String accNum) async {
    try {
      final params = _buildParams({'AccNum': accNum});
      final body = await _post('/QueryAccAuth.aspx', params);
      final json = _tryParseJson(body);
      if (json != null && json['Code'] == '1') {
        AppLogger.instance.network(LogLevel.info, 'ecard 认证成功');
        return true;
      }
      AppLogger.instance.network(
        LogLevel.warn,
        'ecard 认证失败: ${json?['Msg'] ?? body}',
      );
      return false;
    } on EcardConnectionException {
      rethrow;
    } catch (e) {
      AppLogger.instance.network(LogLevel.error, 'ecard 认证异常: $e');
      return false;
    }
  }

  Future<String?> getAccInfo(String accNum) async {
    try {
      final params = _buildParams({'AccNum': accNum});
      final body = await _post('/QueryAccInfoH.aspx', params);
      final json = _tryParseJson(body);
      if (json != null && json['Code'] == '1') {
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

  Future<String?> getQRCode(
    String accNum, {
    bool Function()? shouldContinue,
  }) async {
    try {
      // 发送前校验：登录态已变化则不出码。
      if (shouldContinue?.call() == false) return null;
      final params = _buildParams({'AccNum': accNum});
      final body = await _post('/GetQRCode.aspx', params);
      if (shouldContinue?.call() == false) return null;
      final json = _tryParseJson(body);
      if (json != null && json['Code'] == '1') {
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
      final body = await _post('/GetQRCodeInfo.aspx', params);
      final json = _tryParseJson(body);
      if (json != null) {
        if (AppLogger.instance.config.value.networkVerboseEnabled) {
          AppLogger.instance.network(LogLevel.debug, 'ecard QR状态响应: $json');
        }
        final code = json['Code'] as String? ?? '';
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
  /// [shouldContinue] 在每个网络请求返回后、发送下一个请求前调用；返回
  /// false 时立即中止且不再发送后续请求（防止 QueryAccAuth 在途期间登出/
  /// 切账号后，仍用旧 studentId 继续请求）。缺省 null 保持既有行为。
  Future<QRCodeInitResult> initializeAndCreateQRCode(
    String studentId, {
    bool Function()? shouldContinue,
  }) async {
    bool continueRequested() => shouldContinue?.call() ?? true;
    const aborted = QRCodeInitResult(error: '登录状态已变更，已取消本次取码');

    try {
      final accNum = studentIdToAccNum(studentId);
      final authOk = await queryAccAuth(accNum);
      if (!continueRequested()) return aborted;
      if (!authOk) {
        return QRCodeInitResult(error: '校园卡认证失败');
      }

      await getAccInfo(accNum);
      if (!continueRequested()) return aborted;

      final qrCode = await getQRCode(accNum, shouldContinue: shouldContinue);
      if (!continueRequested()) return aborted;
      if (qrCode == null) {
        return QRCodeInitResult(error: '获取消费码失败');
      }

      return QRCodeInitResult(
        accNum: accNum,
        accName: _cachedAccName,
        qrCode: qrCode,
      );
    } on EcardConnectionException catch (e) {
      if (!continueRequested()) return aborted;
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
