import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/login_page_detection.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';

const _casLoginHtml = '''
<html>
  <form id="fm1">
    <input type="hidden" name="lt" value="LT-1" />
    <input type="hidden" name="execution" value="e1s1" />
  </form>
</html>
''';

// 与 zhengfang_auth_test.dart 中真实登录页形态一致。
const _zhengfangFullLoginHtml = '''
<title>教学管理信息服务平台</title>
<form action="/jwglxt/xtgl/login_slogin.html" method="post">
  <input type="hidden" id="csrftoken" name="csrftoken" value="token" />
  <h5>用户登录</h5>
  <input type="text" class="form-control" name="yhm" id="yhm" />
  <input type="text" class="form-control" name="mm" id="mm" />
  <input name="yzm" type="text" id="yzm" class="form-control" />
  <button type="button" id="dl">登 录</button>
</form>
<script src="/jwglxt/js/globalweb/login/login.js"></script>
''';

// 与 academic_auth_guard_test.dart 的最小严格命中 fixture 一致。
const _zhengfangMinimalLoginHtml =
    '<html><form action="/jwglxt/xtgl/login_slogin.html">'
    '<input id="yhm" name="yhm" />'
    '<input id="mm" name="mm" />'
    '</form></html>';

const _zhengfangAuthedHtml = '''
<title>教学管理信息服务平台</title>
<div>欢迎使用嘉兴大学教学综合服务平台</div>
<a href="/jwglxt/xtgl/index_initMenu.html?jsdm=xs">首页</a>
''';

const _wrappedCas = 'https://webvpn.zjxu.edu.cn/https/abc/cas/login?service=x';

void main() {
  group('URL 判定', () {
    final cases = <(String, String, LoginPageKind?)>[
      (
        '真实 CAS 登录入口',
        'https://newca.zjxu.edu.cn/cas/login?service=https://m.zjxu.edu.cn',
        LoginPageKind.unifiedAuth,
      ),
      (
        '相对 CAS 登录入口',
        '/cas/login?service=https://m.zjxu.edu.cn',
        LoginPageKind.unifiedAuth,
      ),
      ('WebVPN 代理的 CAS 登录页', _wrappedCas, LoginPageKind.unifiedAuth),
      (
        'WebVPN 网关登录页',
        'https://webvpn.zjxu.edu.cn/login',
        LoginPageKind.webVpnGateway,
      ),
      (
        'WebVPN 网关登录页（大小写）',
        'HTTPS://WEBVPN.ZJXU.EDU.CN/Login',
        LoginPageKind.webVpnGateway,
      ),
      (
        '教务登录入口（绝对）',
        'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html?jsdm=xs',
        LoginPageKind.zhengfang,
      ),
      ('教务登录入口（相对）', '/jwglxt/xtgl/login_slogin.html', LoginPageKind.zhengfang),
      ('教务验证码地址', '/jwglxt/kaptcha?time=1', LoginPageKind.zhengfang),
      (
        '教务已认证首页',
        'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
        null,
      ),
      (
        'WebVPN 代理的教务首页',
        'https://webvpn.zjxu.edu.cn/https/abc/jwglxt/xtgl/index_initMenu.html',
        null,
      ),
      ('WebVPN 非 /login 路径', 'https://webvpn.zjxu.edu.cn/login/other', null),
      ('CAS 已认证客户端路径', 'https://newca.zjxu.edu.cn/casclient/login', null),
      ('空串', '', null),
      ('空白', '   ', null),
    ];
    for (final (name, url, expected) in cases) {
      test('classifyLoginUrl: $name', () {
        expect(classifyLoginUrl(url), expected);
      });
    }

    test('classifyLoginUrl: null 输入', () {
      expect(classifyLoginUrl(null), isNull);
    });

    test('classifyLoginUrl: kinds 过滤只保留指定类别', () {
      expect(
        classifyLoginUrl(_wrappedCas, kinds: {LoginPageKind.zhengfang}),
        isNull,
      );
      expect(
        classifyLoginUrl(
          '/jwglxt/xtgl/login_slogin.html',
          kinds: casAndGatewayLoginKinds,
        ),
        isNull,
      );
      expect(
        classifyLoginUrl(
          'https://webvpn.zjxu.edu.cn/login',
          kinds: casAndGatewayLoginKinds,
        ),
        LoginPageKind.webVpnGateway,
      );
    });

    test('严格 CAS 入口不含 WebVPN 代理形态，宽口径含', () {
      expect(isUnifiedAuthLoginEntryUrl(_wrappedCas), isFalse);
      expect(isCasLoginUrl(_wrappedCas), isTrue);
      expect(
        isUnifiedAuthLoginEntryUrl('https://other.zjxu.edu.cn/cas/login'),
        isFalse,
      );
    });

    test('历史别名与口径保持', () {
      expect(
        isZhengfangGatewayLoginUrl('https://webvpn.zjxu.edu.cn/login'),
        isTrue,
      );
      expect(
        isZhengfangLoginEntryUrl('/jwglxt/xtgl/login_slogin.html'),
        isTrue,
      );
      expect(isZhengfangLoginEntryUrl(_wrappedCas), isTrue);
      // 历史口径不含验证码地址。
      expect(isZhengfangLoginEntryUrl('/jwglxt/kaptcha'), isFalse);
    });

    test('WebVPN 门户页', () {
      expect(isWebVpnPortalUrl('https://webvpn.zjxu.edu.cn/'), isTrue);
      expect(isWebVpnPortalUrl('https://webvpn.zjxu.edu.cn/m/portal'), isTrue);
      expect(isWebVpnPortalUrl('https://webvpn.zjxu.edu.cn/login'), isTrue);
      expect(
        isWebVpnPortalUrl('https://webvpn.zjxu.edu.cn/https/abc/x'),
        isFalse,
      );
      expect(isWebVpnPortalUrl('https://example.com/'), isFalse);
    });
  });

  group('HTML 判定', () {
    final cases = <(String, String, LoginPageKind?)>[
      ('CAS 登录表单', _casLoginHtml, LoginPageKind.unifiedAuth),
      ('CAS 验证码标记', '<img src="/cas/captcha.html">', LoginPageKind.unifiedAuth),
      ('CAS 标题文案', '<title>统一身份认证</title>', LoginPageKind.unifiedAuth),
      ('教务完整登录页', _zhengfangFullLoginHtml, LoginPageKind.zhengfang),
      ('教务最小登录页', _zhengfangMinimalLoginHtml, LoginPageKind.zhengfang),
      ('教务已认证页', _zhengfangAuthedHtml, null),
      ('下游服务页', '<html><body>欢迎进入服务大厅</body></html>', null),
      ('空串', '', null),
    ];
    for (final (name, html, expected) in cases) {
      test('classifyLoginHtml: $name', () {
        expect(classifyLoginHtml(html), expected);
      });
    }

    test('classifyLoginHtml: null 与 kinds 过滤', () {
      expect(classifyLoginHtml(null), isNull);
      expect(
        classifyLoginHtml(
          _zhengfangFullLoginHtml,
          kinds: casAndGatewayLoginKinds,
        ),
        isNull,
      );
      expect(
        classifyLoginHtml(_casLoginHtml, kinds: {LoginPageKind.zhengfang}),
        isNull,
      );
    });
  });

  group('响应级组合判定', () {
    final requestUri = Uri.parse('https://jwzx.zjxu.edu.cn/jwglxt/x');

    final cases = <(String, Map<String, Object?>, LoginPageKind?)>[
      (
        '最终落地 CAS 登录页',
        {'realUrl': 'https://newca.zjxu.edu.cn/cas/login?service=x'},
        LoginPageKind.unifiedAuth,
      ),
      (
        '最终落地 WebVPN 网关登录',
        {'realUrl': 'https://webvpn.zjxu.edu.cn/login'},
        LoginPageKind.webVpnGateway,
      ),
      (
        '302 跳 CAS（相对）',
        {'statusCode': 302, 'location': '/cas/login?service=x'},
        LoginPageKind.unifiedAuth,
      ),
      (
        '303 跳 WebVPN 代理 CAS',
        {'statusCode': 303, 'location': _wrappedCas},
        LoginPageKind.unifiedAuth,
      ),
      (
        '302 跳教务登录',
        {'statusCode': 302, 'location': '/jwglxt/xtgl/login_slogin.html'},
        LoginPageKind.zhengfang,
      ),
      ('301 不算登录跳转', {'statusCode': 301, 'location': '/cas/login'}, null),
      (
        '200 的 location 头被忽略',
        {'statusCode': 200, 'location': '/cas/login'},
        null,
      ),
      (
        '200 CAS 登录 HTML',
        {'statusCode': 200, 'html': _casLoginHtml},
        LoginPageKind.unifiedAuth,
      ),
      (
        '200 教务登录 HTML',
        {'statusCode': 200, 'html': _zhengfangMinimalLoginHtml},
        LoginPageKind.zhengfang,
      ),
      ('html 为 null 跳过正文', {'statusCode': 200}, null),
      (
        '正常业务页',
        {
          'realUrl': 'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html',
          'statusCode': 200,
          'html': _zhengfangAuthedHtml,
        },
        null,
      ),
      (
        'URL 教务 + 正文 CAS：统一认证优先',
        {'realUrl': '/jwglxt/xtgl/login_slogin.html', 'html': _casLoginHtml},
        LoginPageKind.unifiedAuth,
      ),
      (
        'URL CAS + 正文教务：统一认证优先',
        {'realUrl': _wrappedCas, 'html': _zhengfangMinimalLoginHtml},
        LoginPageKind.unifiedAuth,
      ),
      (
        '网关优先于 CAS 正文',
        {'realUrl': 'https://webvpn.zjxu.edu.cn/login', 'html': _casLoginHtml},
        LoginPageKind.webVpnGateway,
      ),
    ];
    for (final (name, args, expected) in cases) {
      test('classifyLoginExchange: $name', () {
        expect(
          classifyLoginExchange(
            realUrl: args['realUrl'] as String?,
            statusCode: args['statusCode'] as int?,
            location: args['location'] as String?,
            requestUri: requestUri,
            html: args['html'] as String?,
          ),
          expected,
        );
      });
    }

    test('相对 location 按 requestUri 解析后再判定', () {
      expect(
        classifyLoginExchange(
          statusCode: 302,
          location: 'login_slogin.html',
          requestUri: Uri.parse('https://jwzx.zjxu.edu.cn/jwglxt/xtgl/'),
        ),
        LoginPageKind.zhengfang,
      );
      expect(
        classifyLoginExchange(
          statusCode: 302,
          location: '/jwglxt/xtgl/login_slogin.html',
          requestUri: Uri.parse('https://jwzx.zjxu.edu.cn/jwglxt/xtgl/'),
        ),
        LoginPageKind.zhengfang,
      );
    });

    test('isCasLoginExchange 只认统一认证（含代理形态），不含网关 / 教务', () {
      expect(
        isCasLoginExchange(
          realUrl: 'https://newca.zjxu.edu.cn/cas/login?service=x',
        ),
        isTrue,
      );
      expect(
        isCasLoginExchange(statusCode: 302, location: _wrappedCas),
        isTrue,
      );
      expect(isCasLoginExchange(html: _casLoginHtml), isTrue);
      expect(
        isCasLoginExchange(realUrl: 'https://webvpn.zjxu.edu.cn/login'),
        isFalse,
      );
      expect(isCasLoginExchange(html: _zhengfangMinimalLoginHtml), isFalse);
    });

    test('isWebVpnGatewayLoginBounce：URL 任一登录类别或 CAS 正文', () {
      expect(
        isWebVpnGatewayLoginBounce('https://webvpn.zjxu.edu.cn/login', ''),
        isTrue,
      );
      expect(isWebVpnGatewayLoginBounce(_wrappedCas, ''), isTrue);
      expect(
        isWebVpnGatewayLoginBounce('/jwglxt/xtgl/login_slogin.html', ''),
        isTrue,
      );
      expect(
        isWebVpnGatewayLoginBounce(
          'https://webvpn.zjxu.edu.cn/https/abc/x',
          _casLoginHtml,
        ),
        isTrue,
      );
      // 正文只认统一认证，教务登录页正文不是网关 bounce。
      expect(
        isWebVpnGatewayLoginBounce(
          'https://webvpn.zjxu.edu.cn/https/abc/x',
          _zhengfangMinimalLoginHtml,
        ),
        isFalse,
      );
      expect(
        isWebVpnGatewayLoginBounce(
          'https://webvpn.zjxu.edu.cn/https/abc/x',
          '<html>ok</html>',
        ),
        isFalse,
      );
    });
  });

  group('邻接判定', () {
    test('looksLikeWeChatAuthHtml', () {
      expect(looksLikeWeChatAuthHtml('<!DOCTYPE html><html></html>'), isTrue);
      expect(looksLikeWeChatAuthHtml('  <html><body/></html>'), isTrue);
      expect(looksLikeWeChatAuthHtml('{"_auth_provider_":1}'), isTrue);
      expect(
        looksLikeWeChatAuthHtml('{"u":"https://open.weixin.qq.com/connect"}'),
        isTrue,
      );
      expect(looksLikeWeChatAuthHtml('#wechat_redirect'), isTrue);
      expect(looksLikeWeChatAuthHtml('{"success":true}'), isFalse);
      expect(looksLikeWeChatAuthHtml(''), isFalse);
    });

    test('looksLikeLoginExpiredMessage（宽松文案判定）', () {
      for (final message in [
        '请先登录',
        '登陆已过期',
        'Session timeout',
        'token expired',
        '重新登录',
      ]) {
        expect(looksLikeLoginExpiredMessage(message), isTrue, reason: message);
      }
      expect(looksLikeLoginExpiredMessage('查询成功'), isFalse);
      expect(looksLikeLoginExpiredMessage(''), isFalse);
    });
  });

  group('调用点口径（统一判据的下游）', () {
    AcademicEntrySessionStatus entry(
      int status, {
      String location = '',
      String html = '',
    }) => classifyAcademicEntryResponse(
      mode: ZhengfangMode.direct,
      requestUri: Uri.parse(
        'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html',
      ),
      status: status,
      location: location,
      html: html,
    );

    test('教务入口分类：统一认证 / 网关 vs 教务登录', () {
      expect(
        entry(302, location: 'https://newca.zjxu.edu.cn/cas/login?service=x'),
        AcademicEntrySessionStatus.unifiedLoginRequired,
      );
      expect(
        entry(302, location: _wrappedCas),
        AcademicEntrySessionStatus.unifiedLoginRequired,
      );
      expect(
        entry(302, location: 'https://webvpn.zjxu.edu.cn/login'),
        AcademicEntrySessionStatus.unifiedLoginRequired,
      );
      expect(
        entry(200, html: _casLoginHtml),
        AcademicEntrySessionStatus.unifiedLoginRequired,
      );
      expect(
        entry(302, location: '/jwglxt/xtgl/login_slogin.html'),
        AcademicEntrySessionStatus.academicLoginRequired,
      );
      expect(
        entry(302, location: '/jwglxt/kaptcha'),
        AcademicEntrySessionStatus.academicLoginRequired,
      );
      expect(
        entry(200, html: _zhengfangMinimalLoginHtml),
        AcademicEntrySessionStatus.academicLoginRequired,
      );
      // 正文只在 200 时参与判定。
      expect(
        entry(500, html: _casLoginHtml),
        isNot(AcademicEntrySessionStatus.unifiedLoginRequired),
      );
      // 教务登录 URL + 统一认证正文：统一认证优先。
      expect(
        entry(
          200,
          location: '/jwglxt/xtgl/login_slogin.html',
          html: _casLoginHtml,
        ),
        AcademicEntrySessionStatus.unifiedLoginRequired,
      );
    });

    bool expired(int status, {String? location, Object? data}) {
      final response = Response<Object?>(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: status,
        headers: Headers.fromMap({
          if (location != null) 'location': [location],
        }),
        data: data,
      );
      return AcademicAuthGuard.isAuthExpiredResponse(response);
    }

    test('guard 过期判定：状态码 / 跳转 / 严格登录页', () {
      expect(expired(901), isTrue);
      expect(expired(401), isTrue);
      expect(expired(302, location: '/jwglxt/xtgl/login_slogin.html'), isTrue);
      expect(expired(303, location: '/jwglxt/kaptcha'), isTrue);
      expect(expired(302, location: _wrappedCas), isTrue);
      expect(
        expired(302, location: 'https://webvpn.zjxu.edu.cn/login'),
        isTrue,
      );
      expect(expired(302, location: 'https://jwzx.zjxu.edu.cn/other'), isFalse);
      expect(expired(200, data: _zhengfangMinimalLoginHtml), isTrue);
      // guard 在 200 只认正方登录页，不把 CAS 正文当教务过期（保持原口径）。
      expect(expired(200, data: _casLoginHtml), isFalse);
      expect(expired(200, data: _zhengfangAuthedHtml), isFalse);
      expect(expired(403), isFalse);
      expect(expired(200, data: <String, Object?>{'a': 1}), isFalse);
    });
  });
}
