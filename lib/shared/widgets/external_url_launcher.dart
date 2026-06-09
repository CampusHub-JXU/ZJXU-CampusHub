import 'package:url_launcher/url_launcher.dart';

import '../../core/logging/app_logger.dart';

Future<void> launchExternalUriFromWebView(
  Uri uri, {
  String logPrefix = '外部链接',
}) async {
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      AppLogger.instance.webview(LogLevel.warn, '$logPrefix 唤起失败: $uri');
    }
  } catch (error) {
    AppLogger.instance.webview(
      LogLevel.warn,
      '$logPrefix 唤起异常: $uri error=$error',
    );
  }
}
