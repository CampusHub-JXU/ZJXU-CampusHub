import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/logging/app_logger.dart';
import 'external_url_launcher.dart';

/// 把 WebView 附件交给系统下载服务（Android DownloadManager）。
///
/// 下载在系统进程执行，不共享 WebView 的 Cookie，所以这里显式从
/// [CookieManager] 取目标 URL 的 Cookie 并注入下载请求头。
class SystemDownloader {
  SystemDownloader._();

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/download');

  /// 入队一次系统下载；返回是否成功入队。
  static Future<bool> enqueue({
    required String url,
    required String fileName,
    String? mimeType,
    String? userAgent,
    String? referer,
  }) async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      final cookieHeader = cookies
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');

      final enqueued = await _channel.invokeMethod<bool>('enqueueDownload', {
        'url': url,
        'fileName': fileName,
        if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
        if (userAgent != null && userAgent.isNotEmpty) 'userAgent': userAgent,
        if (cookieHeader.isNotEmpty) 'cookie': cookieHeader,
        if (referer != null && referer.isNotEmpty) 'referer': referer,
      });
      return enqueued ?? false;
    } on PlatformException catch (error, stackTrace) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '系统下载入队失败: ${scrubSensitiveUrl(url)}',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
