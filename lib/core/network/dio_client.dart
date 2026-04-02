import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'cookie_interceptor.dart';

class DioClient {
  DioClient._();
  static final DioClient instance = DioClient._();
  final CookieJar cookieJar = CookieJar();
  late final Dio dio = Dio(
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
  )..interceptors.add(buildCookieInterceptor(cookieJar));
}
