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

enum WebViewQuickFillKind { zhengfang, unifiedAuth }

WebViewQuickFillKind? detectWebViewQuickFillKind(String currentUrl) {
  final normalizedUrl = currentUrl.trim().toLowerCase();
  if (normalizedUrl.isEmpty) return null;
  if (normalizedUrl.contains('/xtgl/login_slogin.html')) {
    return WebViewQuickFillKind.zhengfang;
  }
  if (normalizedUrl.contains('/cas/login')) {
    return WebViewQuickFillKind.unifiedAuth;
  }
  // 图书馆（libapp）站点自带的登录页：一卡通号 + 卡证密码，
  // 表单字段为 login_name / password（设备实测 2026-09-12）。
  if (normalizedUrl.contains('/user/index/login')) {
    return WebViewQuickFillKind.unifiedAuth;
  }
  return null;
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
