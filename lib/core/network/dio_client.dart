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
          final code = response.statusCode;
          final uri = response.requestOptions.uri;
          if (code == 302 || code == 303) {
            final location = response.headers.value('location') ?? '';
            AppLogger.instance.info('← $code $uri → $location');
            if (location.contains('login_slogin') ||
                location.contains('kaptcha')) {
              AppLogger.instance.info('检测到重定向到登录/验证码页面，可能未在校园网环境');
            }
          } else {
            AppLogger.instance.debug('← $code $uri');
          }
          handler.next(response);
        },
        onError: (error, handler) {
          AppLogger.instance.error(
            '请求失败: ${error.type} - ${error.requestOptions.uri} - ${error.message}',
          );
          handler.next(error);
        },
      ),
    );
    _applyProxyMode(client);
    return client;
  }
}
