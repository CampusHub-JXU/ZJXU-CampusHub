import 'package:flutter/services.dart';

import '../../core/logging/app_logger.dart';

class SecondClassroomWechatLauncher {
  SecondClassroomWechatLauncher._();

  static final SecondClassroomWechatLauncher instance =
      SecondClassroomWechatLauncher._();

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/wechat');

  Future<bool> openUrl(String url) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) return false;

    try {
      final opened = await _channel.invokeMethod<bool>('openUrlInWeChat', {
        'url': trimmedUrl,
      });
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      AppLogger.instance.webview(
        LogLevel.error,
        '打开微信网页失败: ${error.message ?? error.code}',
      );
      return false;
    } catch (error) {
      AppLogger.instance.webview(LogLevel.error, '打开微信网页异常: $error');
      return false;
    }
  }
}
