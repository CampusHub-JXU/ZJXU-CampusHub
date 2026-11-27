part of 'webview_page.dart';

const _serviceHallHomeUrl =
    'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home';
const _serviceHallHost = 'mobilehall.zjxu.edu.cn';
const _serviceHallPath = '/mportal/start/index.html';
const _serviceHallHomeFragment = '/business/ydd/portal/home';
const _webViewConsoleNoiseKeywords = <String>[
  'dingtalk bridge',
  'weixinjsbridge',
  '__wxjs_environment',
  'not implemented on the current platform',
  'text input plugin',
  'inputmethodmanager',
  'keyboard',
];

/// WebView 侧的统一认证登录入口判定：newca 直连 CAS，或 WebVPN 代理后的
/// CAS 登录页。
///
/// [isUnifiedAuthLoginEntryUrl] 只认 `newca.zjxu.edu.cn`；WebVPN 会把 CAS
/// 登录页代理成 `https://webvpn.zjxu.edu.cn/(http|https)/<hash>/cas/login…`。
/// 受保护业务页若渲染它，就会把学校 CAS 的 H5 登录表单直接交给用户；这里
/// 把代理形态一并识别，供受保护 WebView 在导航阶段拦截。
bool isWebViewCasLoginEntryUrl(String currentUrl) {
  if (isUnifiedAuthLoginEntryUrl(currentUrl)) return true;

  final uri = Uri.tryParse(currentUrl.trim());
  if (uri == null) return false;
  if (uri.host.toLowerCase() != 'webvpn.zjxu.edu.cn') return false;
  return uri.path.toLowerCase().contains('/cas/login');
}

/// SSO 中间跳转页判定：CAS oauth 系落地页、图书馆 ticket 消费入口与钉钉授权页。
///
/// 这些页面不是 CAS 登录入口（见 [isWebViewCasLoginEntryUrl]），也不是
/// 业务页，而是 SSO 链路的中间跳转（CAS `oauth/forward/<token>`、
/// `/oauth2.0/…`、图书馆 `ssoFromDingDing` 的 ticket 消费跳转、钉钉
/// `dd.runtime` 授权）。受保护 WebView 落到它们时不能重置 bounce 计数，
/// 否则「一次自动重试」契约被无限重新武装——图书馆 SSO 链在这些页之间
/// 无限回跳的根因之一（2026-09-13 设备实测）。判定范围：
/// - `newca.zjxu.edu.cn` 上 `/cas/`、`/oauth2/`、`/oauth/` 开头的路径；
/// - `libapp.zjxu.edu.cn` 上的 `Info/Thirdparty/ssoFromDingDing`：ticket
///   消费后落到 CAS `oauth/forward`，本身是 SSO 链一环而非业务页；
/// - 任意 `dingtalk.com` 主机（`login.dingtalk.com`、`oapi.dingtalk.com` 等，
///   WebVPN 不代理外网域，只认直连形态）；
/// - WebVPN 代理形态（`webvpn.zjxu.edu.cn`）：代理内层路径包含同样标记
///   （内层路径跟在加密主机段之后，只能按 contains 判定）。
bool isSsoIntermediateLandingUrl(String currentUrl) {
  final raw = currentUrl.trim();
  if (raw.isEmpty) return false;

  final uri = Uri.tryParse(raw);
  if (uri == null) return false;

  const casMarkers = <String>['/cas/', '/oauth2/', '/oauth/'];
  const librarySsoEntryPath = '/info/thirdparty/ssofromdingding';
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();

  if (host == 'newca.zjxu.edu.cn') {
    return casMarkers.any(path.startsWith);
  }
  if (host == 'libapp.zjxu.edu.cn') {
    return path.startsWith(librarySsoEntryPath);
  }
  if (host == 'dingtalk.com' || host.endsWith('.dingtalk.com')) {
    return true;
  }
  if (host == 'webvpn.zjxu.edu.cn') {
    return casMarkers.any(path.contains) || path.contains(librarySsoEntryPath);
  }
  return false;
}

/// 教务（正方）登录页判定：快速填充只保留教务表单。
///
/// 统一认证 / 一卡通 CAS 登录页（含 WebVPN 代理形态）不得识别为快速填充
/// 目标：禁止在 CAS H5 注入一卡通凭据，也不得渲染「一卡通快速填充」UI。
bool isZhengfangQuickFillTarget(String currentUrl) {
  return currentUrl.trim().toLowerCase().contains('/xtgl/login_slogin.html');
}

String selectLoadedWebViewUrl({
  required String fallbackUrl,
  String? reportedUrl,
  String? controllerUrl,
}) {
  for (final candidate in [controllerUrl, reportedUrl, fallbackUrl]) {
    final value = candidate?.trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return '';
}

bool isServiceHallHomeUrl(String currentUrl) {
  final raw = currentUrl.trim();
  if (raw.isEmpty) return false;

  final uri = Uri.tryParse(raw);
  if (uri == null) return false;
  if (uri.host.toLowerCase() != _serviceHallHost ||
      uri.path != _serviceHallPath) {
    return false;
  }

  final fragment = uri.fragment.trim();
  if (fragment.isEmpty) return false;

  final fragmentPath =
      '/${fragment.split('?').first.replaceFirst(RegExp(r'^/+'), '')}';
  return fragmentPath == _serviceHallHomeFragment;
}

bool _isDeniedWeChatSdkRequest(Uri uri) {
  if (uri.host.toLowerCase() != 'webvpn.zjxu.edu.cn') return false;

  final path = uri.path.toLowerCase();
  return path.contains('/open/js/jweixin-1.6.0.js');
}

WebResourceResponse _buildWeChatSdkStubResponse() {
  const script = '''
(function () {
  if (window.wx) return;
  var noop = function () {};
  var wx = {
    config: noop,
    ready: function (cb) { if (typeof cb === 'function') setTimeout(cb, 0); },
    error: noop,
    checkJsApi: noop,
    updateAppMessageShareData: noop,
    updateTimelineShareData: noop,
    onMenuShareTimeline: noop,
    onMenuShareAppMessage: noop,
    hideOptionMenu: noop,
    showOptionMenu: noop,
    closeWindow: noop,
    miniProgram: { getEnv: noop, navigateTo: noop },
    scanQRCode: function (opts) {
      var needResult = (opts && opts.needResult) ? opts.needResult : 0;
      var successCb = (opts && typeof opts.onSuccess === 'function') ? opts.onSuccess : null;
      var errorCb = (opts && typeof opts.onError === 'function') ? opts.onError : null;
      try {
        window.flutter_inappwebview.callHandler('wxScanQRCode', JSON.stringify({ needResult: needResult }))
          .then(function (resultJson) {
            var result = JSON.parse(resultJson || '{}');
            if (result.cancelled) {
              if (errorCb) errorCb({ errMsg: 'scanQRCode:cancel' });
              return;
            }
            if (successCb) {
              var scanResult = result.resultStr || '';
              successCb({ resultStr: scanResult });
            }
          })
          .catch(function (e) {
            if (errorCb) errorCb({ errMsg: 'scanQRCode:fail ' + (e.message || e) });
          });
      } catch (e) {
        if (errorCb) errorCb({ errMsg: 'scanQRCode:fail ' + (e.message || e) });
      }
    }
  };
  window.wx = wx;
})();
''';

  return WebResourceResponse(
    contentType: 'application/javascript',
    contentEncoding: 'utf-8',
    data: Uint8List.fromList(utf8.encode(script)),
    headers: const {'cache-control': 'no-store'},
    statusCode: 200,
    reasonPhrase: 'OK',
  );
}

String? buildEmbeddedWeChatUserAgent(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.iOS:
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.40(0x18002829) NetType/WIFI Language/zh_CN';
    case TargetPlatform.android:
      return 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TP1A.220624.014) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36 MicroMessenger/8.0.40.2420';
    default:
      return null;
  }
}

/// 判断 WebView 历史条目是否为认证/SSO 中转页（如服务大厅 `ssoLogin.html`、CAS 等）。
///
/// 这类页面会在加载后自动向前跳转，若允许用户后退到它们，会立刻再次自动
/// 前进，造成「点返回退不出页面」的死循环。
bool isWebViewAuthRedirectHistoryUrl(String currentUrl) {
  if (isSsoIntermediateLandingUrl(currentUrl) ||
      isWebViewCasLoginEntryUrl(currentUrl)) {
    return true;
  }

  final raw = currentUrl.trim();
  if (raw.isEmpty) return false;

  final uri = Uri.tryParse(raw);
  if (uri == null) return false;

  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();

  if (host == 'newca.zjxu.edu.cn' && path.startsWith('/casclient/')) {
    return true;
  }
  if (host == _serviceHallHost && path.endsWith('/ssologin.html')) {
    return true;
  }
  final fragment = uri.fragment.trim();
  final isEmptyOrRootHash = fragment.isEmpty || fragment == '/';
  if (host == _serviceHallHost &&
      path == _serviceHallPath.toLowerCase() &&
      isEmptyOrRootHash) {
    return true;
  }
  if (host == 'webvpn.zjxu.edu.cn' &&
      (path.contains('/casclient/') ||
          path.contains('/mportal/start/ssologin.html') ||
          (path.contains('/mportal/start/index.html') && isEmptyOrRootHash))) {
    return true;
  }
  return false;
}

/// 从 [currentIndex] 向前查找第一个非认证中转页的 WebView 历史条目步数（负数）。
///
/// 返回 `null` 表示前面没有可退回的真实业务页面（全是 SSO/登录中转页或已是栈底）。
int? resolveWebViewBackStepOffset(List<String> historyUrls, int currentIndex) {
  if (currentIndex <= 0 || currentIndex >= historyUrls.length) {
    return null;
  }
  final currentUrl = historyUrls[currentIndex].trim();
  final currentIsServiceHallHome = isServiceHallHomeUrl(currentUrl);
  for (var index = currentIndex - 1; index >= 0; index--) {
    final candidate = historyUrls[index].trim();
    if (candidate == currentUrl) continue;
    if (currentIsServiceHallHome && isServiceHallHomeUrl(candidate)) continue;
    if (!isWebViewAuthRedirectHistoryUrl(candidate)) {
      return index - currentIndex;
    }
  }
  return null;
}
