import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../platform/safe_invoke.dart';

class WechatLauncher {
  WechatLauncher._();

  static final WechatLauncher instance = WechatLauncher._();

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/wechat');

  /// True means a URL intent was launched, not that the webpage finished loading.
  Future<bool> openUrl(String url) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) return false;

    return safeInvoke<bool, bool>(
      _channel,
      'openUrlInWeChat',
      arguments: {'url': trimmedUrl},
      map: (opened) => opened ?? false,
      missing: false,
      failed: false,
      label: '打开微信网页',
      category: LogCategory.webview,
    );
  }
}
