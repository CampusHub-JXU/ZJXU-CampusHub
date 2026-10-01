import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

/// 调用原生 MethodChannel 并把「通道缺失 / 原生报错」降级为回退值，绝不向 UI
/// 抛平台异常。
///
/// - [MissingPluginException]（非 Android / 单测未注册通道）→ [missing]，不记日志；
/// - [PlatformException] → 记日志（[label] 非空时）后返回 [failed]；
/// - 其它异常：[catchUnknown] 为 true 时同样记日志返回 [failed]，否则原样抛出
///   （保持各调用方原有语义）。
///
/// [map] 把通道原始返回值转成调用方类型（在 try 内执行）。
/// 不适用于需要抛类型化异常（calendar_sync）或带超时 / 隐私日志（验证码 OCR）的通道。
Future<R> safeInvoke<T, R>(
  MethodChannel channel,
  String method, {
  Object? arguments,
  required R Function(T? value) map,
  required R missing,
  required R failed,
  String? label,
  LogCategory category = LogCategory.ui,
  LogLevel level = LogLevel.error,
  bool catchUnknown = true,
}) async {
  try {
    return map(await channel.invokeMethod<T>(method, arguments));
  } on MissingPluginException {
    return missing;
  } on PlatformException catch (error) {
    if (label != null) {
      AppLogger.instance.log(
        level,
        category,
        '$label失败: ${error.message ?? error.code}',
      );
    }
    return failed;
  } catch (error) {
    if (!catchUnknown) rethrow;
    if (label != null) {
      AppLogger.instance.log(level, category, '$label异常: $error');
    }
    return failed;
  }
}
