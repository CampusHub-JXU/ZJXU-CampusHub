import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

Interceptor buildCookieInterceptor(
  CookieJar cookieJar, {
  bool responseOriginOnly = false,
}) {
  return responseOriginOnly
      ? _ResponseOriginCookieManager(cookieJar)
      : CookieManager(cookieJar);
}

class _ResponseOriginCookieManager extends CookieManager {
  _ResponseOriginCookieManager(super.cookieJar);

  @override
  Future<void> saveCookies(Response<dynamic> response) {
    // 复用 CookieManager 的解析，但禁止它把 3xx 的 Cookie 再写入 Location。
    return super.saveCookies(
      Response<dynamic>(
        requestOptions: response.requestOptions,
        headers: response.headers,
        redirects: response.redirects,
      ),
    );
  }
}
