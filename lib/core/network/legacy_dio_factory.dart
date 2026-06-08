import 'package:dio/dio.dart';

import 'network_settings.dart';
import 'proxy_mode.dart';

const campusMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

Dio createCampusBytesDio({
  Duration connectTimeout = const Duration(seconds: 10),
  Duration receiveTimeout = const Duration(seconds: 10),
  Duration? sendTimeout,
  Map<String, dynamic> headers = const {},
  bool? ignoreSystemProxy,
}) {
  final client = Dio(
    BaseOptions(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: {'User-Agent': campusMobileUserAgent, ...headers},
      responseType: ResponseType.bytes,
    ),
  );
  applyProxyModeToDio(
    client,
    ignoreSystemProxy:
        ignoreSystemProxy ?? NetworkSettings.instance.ignoreSystemProxy.value,
  );
  return client;
}

Dio createCampusBytesDioFromOptions(
  BaseOptions? options, {
  Map<String, dynamic> fallbackHeaders = const {},
  bool? ignoreSystemProxy,
}) {
  final existingHeaders = options?.headers;
  return createCampusBytesDio(
    connectTimeout: options?.connectTimeout ?? const Duration(seconds: 10),
    receiveTimeout: options?.receiveTimeout ?? const Duration(seconds: 10),
    sendTimeout: options?.sendTimeout,
    headers: existingHeaders == null
        ? fallbackHeaders
        : Map<String, dynamic>.from(existingHeaders),
    ignoreSystemProxy: ignoreSystemProxy,
  );
}
