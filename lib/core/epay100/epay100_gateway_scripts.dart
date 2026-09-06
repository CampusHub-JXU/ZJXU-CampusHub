part of 'epay100_gateway.dart';

// 纯 JS 注入脚本与文本工具（从 epay100_gateway.dart 机械拆分，无逻辑改动）。

/// 与可见 WebViewPage 相同的钉钉容器仿真（epay100 页面按容器分支行为）。
const _dingTalkBridgeStub = '''
(function() {
  var ddMock = {
    ready: function(cb) { if (typeof cb === 'function') setTimeout(cb, 0); },
    error: function(cb) {},
    config: function() {},
    biz: {
      navigation: {
        setTitle: function() {},
        setRight: function() {},
        close: function() {}
      },
      util: {
        openLink: function(opts) {
          if (opts && opts.url) { window.location.href = opts.url; }
        }
      }
    },
    permission: {
      requestAuthCode: function(opts) {
        if (opts && typeof opts.onFail === 'function') {
          opts.onFail({ errorCode: 3, errorMessage: 'not supported' });
        }
      }
    },
    runtime: {
      permission: {
        requestAuthCode: function(opts) {
          if (opts && typeof opts.onFail === 'function') {
            opts.onFail({ errorCode: 3, errorMessage: 'not supported' });
          }
        }
      }
    },
    device: {
      notification: {
        alert: function(opts) {
          if (opts && typeof opts.onSuccess === 'function') opts.onSuccess();
        }
      }
    },
    env: { platform: 'notInDingTalk' },
    version: '7.0.0'
  };
  try {
    Object.defineProperty(window, 'dd', {
      get: function() { return ddMock; },
      set: function() {},
      configurable: true
    });
  } catch (e) {}
})();
''';

/// 压缩空白并截断，用于诊断日志展示未知响应体开头。
/// 压缩空白并截断，用于诊断日志展示未知响应体开头。
String _bodyHead(String raw, {int limit = 120}) {
  final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= limit) return collapsed;
  return '${collapsed.substring(0, limit)}…';
}

/// evaluateJavascript 对字符串返回值可能再包一层 JSON 编码，逐层解开。
/// evaluateJavascript 对字符串返回值可能再包一层 JSON 编码，逐层解开。
String _unwrapStringResult(Object? result) {
  var value = result;
  for (var i = 0; i < 3; i++) {
    if (value is! String) break;
    final trimmed = value.trim();
    if (trimmed.startsWith('{')) return trimmed;
    try {
      value = jsonDecode(trimmed);
    } catch (_) {
      return trimmed;
    }
  }
  return value == null ? '' : value.toString();
}

extension _GatewayScripts on HeadlessEpay100Gateway {
  /// 会话首个 epay100 文档开头清掉遗留 token，逼页面重新走 checkCas。
  ///
  /// 同时挂钩 `localStorage.setItem` 记录 token 写入时间戳，就绪判定据此区分
  /// 「本次会话新签发」与「上次会话遗留」。
  String _freshCredentialsScript({required bool clearFingerprint}) {
    return '''
(function() {
  var TOKEN = '${HeadlessEpay100Gateway._tokenKey}';
  var UUID = '${HeadlessEpay100Gateway._clientUuidKey}';
  var TS = '${HeadlessEpay100Gateway._tokenTsKey}';
  var CLEANED = '${HeadlessEpay100Gateway._cleanedKey}';
  try {
    if (location.hostname === 'www.epay100.cn' &&
        !sessionStorage.getItem(CLEANED)) {
      sessionStorage.setItem(CLEANED, '1');
      try { localStorage.removeItem(TOKEN); } catch (e) {}
      try { localStorage.removeItem(TS); } catch (e) {}
      if (${clearFingerprint ? 'true' : 'false'}) {
        try { localStorage.removeItem(UUID); } catch (e) {}
        try { sessionStorage.removeItem(UUID); } catch (e) {}
      }
    }
  } catch (e) {}
  try {
    var original = Storage.prototype.setItem;
    Storage.prototype.setItem = function(key, value) {
      try {
        if (key === TOKEN) original.call(localStorage, TS, String(Date.now()));
      } catch (e) {}
      return original.apply(this, arguments);
    };
  } catch (e) {}
})();
''';
  }

  String get _readyProbeScript =>
      '''
JSON.stringify({
  token: Boolean(localStorage.getItem('${HeadlessEpay100Gateway._tokenKey}')),
  uuid: Boolean(sessionStorage.getItem('${HeadlessEpay100Gateway._clientUuidKey}') ||
                localStorage.getItem('${HeadlessEpay100Gateway._clientUuidKey}')),
  cleaned: Boolean(sessionStorage.getItem('${HeadlessEpay100Gateway._cleanedKey}')),
  ts: Number(localStorage.getItem('${HeadlessEpay100Gateway._tokenTsKey}') || 0)
})
''';

  String _rpcScript(String method, Map<String, String> data) {
    final methodJson = jsonEncode(method);
    final dataJson = jsonEncode(data);
    return '''
window.__jxuRpc = '';
(async function() {
  var result = '';
  try {
    var uuid = sessionStorage.getItem('${HeadlessEpay100Gateway._clientUuidKey}') ||
               localStorage.getItem('${HeadlessEpay100Gateway._clientUuidKey}') || '';
    var token = localStorage.getItem('${HeadlessEpay100Gateway._tokenKey}') || '';
    if (!uuid || !token) {
      result = JSON.stringify({ ok: false, code: 'no-session' });
      window.__jxuRpc = result;
      return;
    }
    var params = new URLSearchParams();
    var method = $methodJson;
    params.set('method', method);
    params.set('uni_id', '${HeadlessEpay100Gateway._uniId}');
    params.set('client_uuid', uuid);
    params.set('attach', '${HeadlessEpay100Gateway._attach}');
    var data = $dataJson;
    for (var k in data) { params.set('data[' + k + ']', data[k]); }
    var rand = Date.now() + '-' + Math.random().toString(36).slice(2, 10);
    var url = 'https://www.epay100.cn/901/${HeadlessEpay100Gateway._uniId}/server/index.php'
      + '?mh901_method=' + encodeURIComponent(method)
      + '&mh901_client_uuid=' + encodeURIComponent(uuid)
      + '&mh901_rand=' + rand;
    var controller = new AbortController();
    var abortTimer = setTimeout(function() { controller.abort(); }, 12000);
    var resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': token,
      },
      credentials: 'include',
      body: params.toString(),
      signal: controller.signal,
    });
    clearTimeout(abortTimer);
    var text = await resp.text();
    var nf = false;
    try { nf = String(window.fetch).indexOf('native code') >= 0; } catch (e) {}
    var parsed = {};
    try { parsed = JSON.parse(text); } catch (e) {}
    result = JSON.stringify({
      ok: true,
      status: Number(resp.status),
      nf: nf,
      code: String(parsed.code || ''),
      msg: String(parsed.msg || ''),
      head: String(text).replace(/\\s+/g, ' ').trim().slice(0, 120),
      body: text
    });
  } catch (e) {
    result = JSON.stringify({
      ok: false,
      code: 'request-failed',
      msg: String(e && e.message ? e.message : e)
    });
  }
  window.__jxuRpc = result;
  return result;
})();
''';
  }
}
