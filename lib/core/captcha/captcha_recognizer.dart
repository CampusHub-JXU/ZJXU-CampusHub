import 'dart:async';

import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

/// 一次验证码识别结果。
///
/// [text] 是已通过白名单校验的答案（大小写原样保留）；[confidence] 只在原生侧
/// 真的给出置信度时才有值，无法提供时为 `null`，绝不伪造数值。
class CaptchaRecognition {
  const CaptchaRecognition({required this.text, this.confidence});

  /// 去空白后长度与字符集均合法的答案。
  final String text;

  /// 原生侧返回的置信度，未知时为 `null`。
  final double? confidence;

  // 不要在这里输出 text，避免把识别答案写进日志。
  @override
  String toString() =>
      'CaptchaRecognition(length: ${text.length}, confidence: $confidence)';
}

/// 验证码识别门面。默认实现走 Android 本地 OCR 插件，失败一律降级为 `null`。
abstract interface class CaptchaRecognizer {
  /// 识别 [bytes]（PNG/JPEG 图片字节）中的验证码。
  ///
  /// [expectedLength] 只接受 4 或 6。任何无法确定答案的情况（非法输入、
  /// 超时、平台不可用、答案格式不符、多候选歧义、低置信度）都返回 `null`，
  /// 调用方必须把 `null` 当作「需要重试/人工兜底」，不能回退成猜测值。
  Future<CaptchaRecognition?> recognize(
    Uint8List bytes, {
    required int expectedLength,
  });
}

/// 默认的验证码识别器实例。
final CaptchaRecognizer defaultCaptchaRecognizer =
    MethodChannelCaptchaRecognizer();

/// 基于方法通道的验证码识别器。
///
/// 对应原生通道 `edu.zjxu.jxucampushub/captcha_ocr` 的 `recognize` 方法，
/// 参数 `bytes` + `expectedLength`，返回候选列表（每项 `text` / `confidence`）。
class MethodChannelCaptchaRecognizer implements CaptchaRecognizer {
  MethodChannelCaptchaRecognizer({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 5),
    this.minimumConfidence = 0.5,
  }) : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'edu.zjxu.jxucampushub/captcha_ocr';
  static const String methodRecognize = 'recognize';

  /// 原生侧是内存位图解码，超过该体积直接拒绝，不进入平台通道。
  static const int maxInputBytes = 512 * 1024;

  /// 验证码只支持 4 位或 6 位。
  static const Set<int> supportedLengths = {4, 6};

  static final RegExp _answerPattern = RegExp(r'^[A-Za-z0-9]+$');
  static final RegExp _whitespacePattern = RegExp(r'\s+');

  final MethodChannel _channel;
  final Duration timeout;
  final double minimumConfidence;

  @override
  Future<CaptchaRecognition?> recognize(
    Uint8List bytes, {
    required int expectedLength,
  }) async {
    // 空/超限输入与不支持的位数直接拒绝，不占用平台资源。
    if (bytes.isEmpty) return null;
    if (bytes.length > maxInputBytes) return null;
    if (!supportedLengths.contains(expectedLength)) return null;

    try {
      final raw = await _channel
          .invokeMethod<Object?>(methodRecognize, <String, Object?>{
            'bytes': bytes,
            'expectedLength': expectedLength,
          })
          .timeout(timeout);
      return _selectCandidate(raw, expectedLength);
    } on TimeoutException {
      // 迟到的原生结果由通道层丢弃；这里只保证调用方拿到 null。
      _logDegrade('验证码识别超时');
      return null;
    } on MissingPluginException {
      // 非 Android / 测试环境：无原生实现，静默降级。
      return null;
    } on PlatformException catch (error) {
      _logDegrade('验证码识别平台异常: ${error.code}');
      return null;
    } on Exception catch (error) {
      // 只记录稳定的异常类型，不写 error.toString()：平台/编解码异常的文本
      // 可能携带识别答案或图片细节，日志只保留失败类别用于排障。
      _logDegrade('验证码识别失败: ${error.runtimeType}');
      return null;
    }
  }

  /// 从候选列表里选唯一答案；任何歧义/非法候选都返回 `null`。
  CaptchaRecognition? _selectCandidate(Object? raw, int expectedLength) {
    if (raw is! List) return null;

    CaptchaRecognition? selected;
    for (final entry in raw) {
      final candidate = _parseCandidate(entry, expectedLength);
      if (candidate == null) continue;
      if (selected == null) {
        selected = candidate;
        continue;
      }
      // 大小写不敏感地比较：文本不同即为歧义，不凭阈值强行挑一个。
      if (selected.text.toLowerCase() != candidate.text.toLowerCase()) {
        return null;
      }
    }
    return selected;
  }

  CaptchaRecognition? _parseCandidate(Object? entry, int expectedLength) {
    if (entry is! Map) return null;
    final text = entry['text'];
    if (text is! String) return null;

    // 只允许去除首尾与字符间空白；不删除任何字符来「凑」出合法答案。
    final normalized = text.replaceAll(_whitespacePattern, '');
    if (normalized.length != expectedLength) return null;
    if (!_answerPattern.hasMatch(normalized)) return null;

    final rawConfidence = entry['confidence'];
    final confidence = rawConfidence is num ? rawConfidence.toDouble() : null;
    // 明确低置信度拒绝；null 表示原生未提供，不能据此拒绝。
    if (confidence != null && confidence < minimumConfidence) return null;

    return CaptchaRecognition(text: normalized, confidence: confidence);
  }

  void _logDegrade(String message) {
    AppLogger.instance.warn(message);
  }
}
