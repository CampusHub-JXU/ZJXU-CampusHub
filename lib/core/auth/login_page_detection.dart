/// 「这次响应是不是登录页 / 登录交换」的**唯一**判定模块（纯函数，无网络、无副作用）。
///
/// 按认证域区分三类登录页（[LoginPageKind]）：
/// - [LoginPageKind.unifiedAuth]：CAS 统一认证登录页，含 WebVPN 网关代理形态
///   （`webvpn.zjxu.edu.cn/https/<enc>/cas/login`）。
/// - [LoginPageKind.webVpnGateway]：WebVPN 网关自身的登录页
///   （`webvpn.zjxu.edu.cn/login`）。
/// - [LoginPageKind.zhengfang]：正方教务登录页 / 验证码页（`login_slogin.html`、
///   `kaptcha`）。
///
/// 业务层、教务 guard、WebVPN 网关会话校验、CAS broker 都从这里取判据，不得
/// 再各写一份 URL / HTML 关键字。判定只读取传入的字符串，不记录响应内容。
library;

/// 登录页所属认证域。
enum LoginPageKind { unifiedAuth, webVpnGateway, zhengfang }

/// 同时关心「统一认证」与「WebVPN 网关」两类登录页（不含教务登录）的调用点
/// 使用：CAS 业务资源（体测 / 畅行嘉大等）命中任一类都意味着要恢复统一认证 /
/// 网关会话，而不是教务登录。
const Set<LoginPageKind> casAndGatewayLoginKinds = {
  LoginPageKind.unifiedAuth,
  LoginPageKind.webVpnGateway,
};

const _webVpnHost = 'webvpn.zjxu.edu.cn';

// ---------------------------------------------------------------------------
// URL 判定
// ---------------------------------------------------------------------------

/// 严格的统一认证登录入口：真实 CAS 域（`newca.zjxu.edu.cn`）或相对地址上的
/// `/cas/login`。**不**含 WebVPN 代理形态——需要「必须是真实 CAS 入口」的场景
/// （如 broker 判定是否真正走过 CAS 签票入口）才用它，其余用 [isCasLoginUrl]。
bool isUnifiedAuthLoginEntryUrl(String currentUrl) {
  final raw = currentUrl.trim();
  if (raw.isEmpty) return false;

  final uri = Uri.tryParse(raw);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  if (host.isEmpty) return path.contains('/cas/login');
  if (host != 'newca.zjxu.edu.cn') return false;
  return path.contains('/cas/login');
}

/// 是否为 WebVPN 网关自身的登录页（`webvpn.zjxu.edu.cn/login`）。
bool isWebVpnGatewayLoginUrl(String currentUrl) {
  final raw = currentUrl.trim();
  if (raw.isEmpty) return false;

  final uri = Uri.tryParse(raw);
  if (uri == null) return false;

  return uri.host.toLowerCase() == _webVpnHost &&
      uri.path.toLowerCase() == '/login';
}

/// 历史名称：[isWebVpnGatewayLoginUrl] 的别名，保留给既有调用点。
bool isZhengfangGatewayLoginUrl(String currentUrl) =>
    isWebVpnGatewayLoginUrl(currentUrl);

/// 统一认证登录页 URL（宽口径）：任意主机上路径含 `/cas/login`，因此同时覆盖
/// 真实 CAS 域、相对地址与 WebVPN 代理形态（`/https/<enc>/cas/login`）。
bool isCasLoginUrl(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('/cas/login');
}

/// 教务（正方）登录页 URL：`/xtgl/login_slogin.html`。
bool isZhengfangLoginPageUrl(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('/xtgl/login_slogin.html');
}

/// 教务（正方）验证码地址（`kaptcha`）：重定向到它同样意味着需要教务登录。
bool isZhengfangCaptchaUrl(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('kaptcha');
}

/// 历史口径：教务登录页 / CAS 登录页 / WebVPN 网关登录页（不含验证码地址）。
bool isZhengfangLoginEntryUrl(String currentUrl) {
  final normalizedUrl = currentUrl.trim().toLowerCase();
  if (normalizedUrl.isEmpty) return false;
  return normalizedUrl.contains('/xtgl/login_slogin.html') ||
      normalizedUrl.contains('/cas/login') ||
      isWebVpnGatewayLoginUrl(currentUrl);
}

/// WebVPN 门户页（`/`、`/m/portal`、`/login`）：网关会话缺失时网关把请求落到
/// 这些页面，而不是代理资源。
bool isWebVpnPortalUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.toLowerCase() != _webVpnHost) return false;
  final path = uri.path.toLowerCase();
  return path == '/' || path == '/m/portal' || path == '/login';
}

/// 把 URL 归入登录页类别；非登录页返回 null。[kinds] 非空时只考虑给定类别。
///
/// 同一 URL 命中多类时优先级：网关 > 统一认证 > 教务。
LoginPageKind? classifyLoginUrl(String? url, {Set<LoginPageKind>? kinds}) {
  if (url == null || url.trim().isEmpty) return null;
  bool want(LoginPageKind kind) => kinds == null || kinds.contains(kind);
  if (want(LoginPageKind.webVpnGateway) && isWebVpnGatewayLoginUrl(url)) {
    return LoginPageKind.webVpnGateway;
  }
  if (want(LoginPageKind.unifiedAuth) && isCasLoginUrl(url)) {
    return LoginPageKind.unifiedAuth;
  }
  if (want(LoginPageKind.zhengfang) &&
      (isZhengfangLoginPageUrl(url) || isZhengfangCaptchaUrl(url))) {
    return LoginPageKind.zhengfang;
  }
  return null;
}

// ---------------------------------------------------------------------------
// HTML 判定
// ---------------------------------------------------------------------------

/// 响应体是否为统一认证（CAS）登录页。
bool looksLikeUnifiedAuthLoginHtml(String html) {
  final normalizedHtml = html.toLowerCase();
  if (normalizedHtml.isEmpty) return false;
  return normalizedHtml.contains('id="fm1"') ||
      normalizedHtml.contains("id='fm1'") ||
      normalizedHtml.contains('name="execution"') ||
      normalizedHtml.contains("name='execution'") ||
      normalizedHtml.contains('name="lt"') ||
      normalizedHtml.contains("name='lt'") ||
      normalizedHtml.contains('/cas/captcha.html') ||
      normalizedHtml.contains('统一身份认证');
}

/// 响应体是否为严格命中的教务（正方）登录页：正常页面里出现「登录」字样不算。
bool looksLikeZhengfangLoginHtml(String html) {
  final normalizedHtml = html.toLowerCase();
  if (normalizedHtml.isEmpty) return false;

  bool containsAny(List<String> patterns) {
    return patterns.any(normalizedHtml.contains);
  }

  final hasLoginAction = containsAny([
    'action="/jwglxt/xtgl/login_slogin.html"',
    "action='/jwglxt/xtgl/login_slogin.html'",
    'action="/xtgl/login_slogin.html"',
    "action='/xtgl/login_slogin.html'",
    '/js/globalweb/login/login.js',
  ]);
  final hasUsernameField = containsAny([
    'id="yhm"',
    "id='yhm'",
    'name="yhm"',
    "name='yhm'",
  ]);
  final hasPasswordField = containsAny([
    'id="mm"',
    "id='mm'",
    'id="hidmm"',
    "id='hidmm'",
    'name="mm"',
    "name='mm'",
  ]);
  final hasCaptchaField = containsAny([
    'id="yzm"',
    "id='yzm'",
    'name="yzm"',
    "name='yzm'",
  ]);
  final hasCsrfField = containsAny([
    'id="csrftoken"',
    "id='csrftoken'",
    'name="csrftoken"',
    "name='csrftoken'",
  ]);
  final hasSubmitButton =
      containsAny(['id="dl"', "id='dl'"]) ||
      normalizedHtml.contains('>登 录<') ||
      normalizedHtml.contains('>登录<') ||
      normalizedHtml.contains('用户登录');
  final credentialFieldCount = [
    hasUsernameField,
    hasPasswordField,
    hasCaptchaField,
  ].where((value) => value).length;

  return (credentialFieldCount >= 2 && (hasLoginAction || hasCsrfField)) ||
      (hasUsernameField && hasPasswordField && hasSubmitButton);
}

/// 把响应体归入登录页类别（HTML 仅有统一认证与教务两种签名）；非登录页返回
/// null。同时命中时统一认证优先。[kinds] 非空时只考虑给定类别。
LoginPageKind? classifyLoginHtml(String? html, {Set<LoginPageKind>? kinds}) {
  if (html == null || html.isEmpty) return null;
  bool want(LoginPageKind kind) => kinds == null || kinds.contains(kind);
  if (want(LoginPageKind.unifiedAuth) && looksLikeUnifiedAuthLoginHtml(html)) {
    return LoginPageKind.unifiedAuth;
  }
  if (want(LoginPageKind.zhengfang) && looksLikeZhengfangLoginHtml(html)) {
    return LoginPageKind.zhengfang;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 响应级组合判定
// ---------------------------------------------------------------------------

/// 判定一次 HTTP 交换是否命中登录页 / 登录跳转，返回命中的类别（否则 null）。
///
/// 依次检查：最终落地 [realUrl]、302/303 的 [location]（相对 [requestUri]
/// 解析）、响应体 [html]。**[html] 传 null 即跳过响应体检查**——调用方需要
/// 「只有 200 才看正文」等状态门控时，自行决定是否传入。
///
/// URL 与正文命中不同类别时，教务以外的类别优先（统一认证 / 网关问题先于
/// 教务登录）。[kinds] 非空时只考虑给定类别。
LoginPageKind? classifyLoginExchange({
  String? realUrl,
  int? statusCode,
  String? location,
  Uri? requestUri,
  String? html,
  Set<LoginPageKind>? kinds,
}) {
  final found = <LoginPageKind>{};

  final urlKind = classifyLoginUrl(realUrl, kinds: kinds);
  if (urlKind != null) found.add(urlKind);

  final code = statusCode ?? 0;
  if ((code == 302 || code == 303) && location != null && location.isNotEmpty) {
    final resolved = requestUri == null
        ? location
        : requestUri.resolve(location).toString();
    final locationKind = classifyLoginUrl(resolved, kinds: kinds);
    if (locationKind != null) found.add(locationKind);
  }

  final htmlKind = classifyLoginHtml(html, kinds: kinds);
  if (htmlKind != null) found.add(htmlKind);

  for (final kind in const [
    LoginPageKind.webVpnGateway,
    LoginPageKind.unifiedAuth,
    LoginPageKind.zhengfang,
  ]) {
    if (found.contains(kind)) return kind;
  }
  return null;
}

/// 一次交换是否命中统一认证（CAS）登录页 / 登录跳转（含 WebVPN 代理形态）。
/// 不含 WebVPN 网关登录与教务登录。
bool isCasLoginExchange({
  String? realUrl,
  int? statusCode,
  String? location,
  Uri? requestUri,
  String? html,
}) =>
    classifyLoginExchange(
      realUrl: realUrl,
      statusCode: statusCode,
      location: location,
      requestUri: requestUri,
      html: html,
      kinds: const {LoginPageKind.unifiedAuth},
    ) !=
    null;

/// WebVPN 网关登录落地页 / CAS 登录页判定：[realUrl] 为最终落地 URL，[html] 为
/// 解码后的正文。教务 H5 入口、`CasRoutedAccess` 与网关会话校验共用同一判据。
///
/// URL 命中任一登录类别（网关 / 统一认证 / 教务登录页或验证码）即为 bounce；
/// 正文只认统一认证登录页（网关不会渲染教务登录页）。
bool isWebVpnGatewayLoginBounce(String realUrl, String html) =>
    classifyLoginUrl(realUrl) != null || looksLikeUnifiedAuthLoginHtml(html);

// ---------------------------------------------------------------------------
// 非 CAS / 非教务的邻接判定（口径同样集中于此）
// ---------------------------------------------------------------------------

/// 第二课堂（twdekt，微信授权）等 JSON 接口返回了 HTML 而不是 JSON：要么是整页
/// HTML，要么带微信 OAuth 跳转标记，意味着微信授权会话失效。不是 CAS / 教务登录。
bool looksLikeWeChatAuthHtml(String text) {
  final trimmed = text.trimLeft();
  if (trimmed.isEmpty) return false;
  final lower = trimmed.toLowerCase();
  return lower.startsWith('<!doctype html') ||
      lower.startsWith('<html') ||
      lower.contains('_auth_provider_') ||
      lower.contains('open.weixin.qq.com') ||
      lower.contains('wechat_redirect');
}

/// 教务 JSON 接口 `message` 字段是否在说「登录已失效」的**宽松文案**判定。
///
/// 只能用于接口返回的短 message 文本；整页 HTML 必须用
/// [looksLikeZhengfangLoginHtml]，否则教学消息里的「登录」字样会误判过期。
bool looksLikeLoginExpiredMessage(String text) {
  final value = text.toLowerCase();
  return value.contains('登录') ||
      value.contains('登陆') ||
      value.contains('session') ||
      value.contains('expired') ||
      value.contains('请先登录') ||
      value.contains('重新登录');
}
