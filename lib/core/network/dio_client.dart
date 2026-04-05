import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import '../logging/app_logger.dart';
import 'cookie_interceptor.dart';
import 'network_settings.dart';
import 'proxy_mode.dart';

class DioClient {
  DioClient._();
  static final DioClient instance = DioClient._();
  final CookieJar cookieJar = CookieJar();
  late final Dio dio = _createDio();

  void applyProxyMode() {
    _applyProxyMode(dio);
  }

  void _applyProxyMode(Dio client) {
    applyProxyModeToDio(
      client,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );
  }

  Dio _createDio() {
    final client = Dio(
      BaseOptions(
        baseUrl: 'https://jwzx.zjxu.edu.cn/jwglxt',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    client.interceptors.add(buildCookieInterceptor(cookieJar));
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          AppLogger.instance.debug('→ ${options.method} ${options.uri}');
          handler.next(options);
        },
        onResponse: (response, handler) {
          AppLogger.instance.debug(
            '← ${response.statusCode} ${response.requestOptions.uri}',
          );
          handler.next(response);
        },
        onError: (error, handler) {
          AppLogger.instance.error(
            '✖ ${error.requestOptions.uri}: ${error.message}',
          );
          handler.next(error);
        },
      ),
    );
    _applyProxyMode(client);
    return client;
  }
}
