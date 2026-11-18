import 'package:dio/dio.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/login_page_detection.dart';
import '../../core/auth/zhengfang_auth.dart';

enum SecondClassroomRoute {
  direct,
  webVpn;

  static final _entry = Uri.parse(CasService.secondClassroom.serviceUrl);
  static final referer = _entry.resolve('wx/index?_WXFTL=0');
  static final _proxyEntry = webVpn.uriFor(_entry);
  static final _proxyPrefix = _proxyEntry.path.substring(
    0,
    _proxyEntry.path.length - _entry.path.length - 1,
  );

  static Uri mobileUri(String path, [Map<String, dynamic>? query]) =>
      _entry.resolve('mobile/$path').replace(queryParameters: query);

  Uri uriFor(Uri directUri) {
    if (this == direct) return directUri;
    // 网关给 twdekt 分配的是 /http/<host>//dekt/ 包装。这里改的是
    // 网关的路由键，真正的 Dio 请求仍以 HTTPS 发往网关。
    return Uri.parse(
      ZhengfangAuth.instance.buildWebVpnProxyUrl(
        directUri
            .replace(scheme: 'http', path: '/${directUri.path}')
            .toString(),
      ),
    );
  }

  Map<String, String> xhrHeaders(Uri requestUri) => {
    'Accept': 'application/json, text/plain, */*',
    'Origin': requestUri.origin,
    'Referer': uriFor(referer).toString(),
    'X-Requested-With': 'XMLHttpRequest',
  };

  static SecondClassroomRoute? forUri(Uri uri) {
    if (uri.scheme != 'https' || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return null;
    }
    if (uri.host == _entry.host && _isDektPath(uri.path)) return direct;
    if (uri.host != _proxyEntry.host ||
        !uri.path.startsWith('$_proxyPrefix/')) {
      return null;
    }
    var innerPath = uri.path.substring(_proxyPrefix.length);
    if (innerPath.startsWith('//')) innerPath = innerPath.substring(1);
    return _isDektPath(innerPath) ? webVpn : null;
  }

  static bool _isDektPath(String path) =>
      path == '/dekt' || path.startsWith('/dekt/');

  /// 仅认可第二课堂代理路径下的 Cookie，避免清掉网关根路径的共享会话。
  static bool isScopedWebVpnCookiePath(String path) =>
      path == _proxyPrefix ||
      path == '$_proxyPrefix/' ||
      forUri(_proxyEntry.replace(path: path)) == webVpn;

  static bool isRedirect(int? status) => switch (status) {
    301 || 302 || 303 || 307 || 308 => true,
    _ => false,
  };

  static Uri? redirectTarget(Response<Object?> response) {
    if (!isRedirect(response.statusCode)) return null;
    final location = response.headers.value('location')?.trim();
    if (location == null || location.isEmpty) return null;
    final uri = Uri.tryParse(location);
    return uri == null ? null : response.requestOptions.uri.resolveUri(uri);
  }

  static bool isLoginUrl(Uri uri) =>
      isWebVpnPortalUrl(uri.toString()) ||
      classifyLoginExchange(
            realUrl: uri.toString(),
            kinds: casAndGatewayLoginKinds,
          ) !=
          null;

  static bool isLoginResponse(Response<Object?> response, Uri? redirect) {
    if (redirect != null && isLoginUrl(redirect)) return true;
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) return false;
    final body = response.data;
    final url = response.realUri.toString();
    return isWebVpnPortalUrl(url) ||
        classifyLoginExchange(
              realUrl: url,
              html: body is String && body.trimLeft().startsWith('<')
                  ? body
                  : null,
              kinds: casAndGatewayLoginKinds,
            ) !=
            null;
  }
}
