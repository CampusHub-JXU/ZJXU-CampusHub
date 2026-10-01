import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';

/// 统一认证登录入口（CAS 登录页），WebVPN 代理登录页 URL 还原时使用。
const _unifiedAuthLoginUrl = 'https://newca.zjxu.edu.cn/cas/login';

/// 把 SSO 重定向 URL 规范化：WebVPN 代理的统一认证登录页还原为真实入口，
/// zhx 站点回调（直连形态）改写为 WebVPN 代理地址。
String normalizeChangxingSsoRedirectUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return raw;

  final unwrappedUnifiedAuthUrl = _unwrapProxiedUnifiedAuthLoginUrl(raw);
  if (unwrappedUnifiedAuthUrl != null) {
    return unwrappedUnifiedAuthUrl;
  }

  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  final host = uri.host.toLowerCase();
  if (host == 'zhx.zjxu.edu.cn' && uri.path.contains('/cas_login_back')) {
    return ZhengfangAuth.instance.buildWebVpnProxyUrl(raw);
  }
  return raw;
}

String? _unwrapProxiedUnifiedAuthLoginUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.toLowerCase() != 'webvpn.zjxu.edu.cn') {
    return null;
  }

  if (!uri.path.toLowerCase().endsWith('/cas/login')) {
    return null;
  }

  final service = uri.queryParameters['service']?.trim() ?? '';
  if (service.isEmpty) return null;

  return Uri.parse(_unifiedAuthLoginUrl)
      .replace(queryParameters: uri.queryParameters)
      .toString();
}

bool isChangxingUnifiedAuthLoginFormResponse(String url, String html) {
  final normalizedUrl = normalizeChangxingSsoRedirectUrl(url);
  return isUnifiedAuthLoginEntryUrl(normalizedUrl) &&
      looksLikeUnifiedAuthLoginHtml(html);
}
