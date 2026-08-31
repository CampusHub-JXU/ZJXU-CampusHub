import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_http_client_adapter.dart';

void main() {
  group('Unified auth url classifiers', () {
    test('treats CAS login pages as unauthenticated entry pages', () {
      expect(
        isUnifiedAuthLoginEntryUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https://mobilehall.zjxu.edu.cn',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthLoginEntryUrl(
          '/cas/login?service=https://mobilehall.zjxu.edu.cn',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https://mobilehall.zjxu.edu.cn',
        ),
        isFalse,
      );
    });

    test('treats downstream service pages as authenticated destinations', () {
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://newca.zjxu.edu.cn/casClient/login/ydd?ticket=abc',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing?ticket=abc',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl('/casClient/login/ydd?ticket=abc'),
        isTrue,
      );
    });

    test('extracts downstream service url from CAS login pages', () {
      expect(
        extractUnifiedAuthServiceUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Flibapp.zjxu.edu.cn%2FInfo%2FThirdparty%2FssoFromDingDing',
        ),
        'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing',
      );
      expect(
        extractUnifiedAuthServiceUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Fnewca.zjxu.edu.cn%2FcasClient%2Flogin%2Fydd',
        ),
        'https://newca.zjxu.edu.cn/casClient/login/ydd',
      );
      expect(
        extractUnifiedAuthServiceUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
        ),
        isNull,
      );
    });

    test('detects CAS service ticket in redirect URL', () {
      expect(
        urlHasCasTicket(
          'https://jwc.zjxu.edu.cn/list.jsp?urltype=tree.TreeTempUrl&wbtreeid=1046&ticket=ST-1-test',
        ),
        isTrue,
      );
      expect(
        urlHasCasTicket(
          'https://newca.zjxu.edu.cn/casClient/login/ydd?ticket=ST-2-test',
        ),
        isTrue,
      );
      expect(
        urlHasCasTicket(
          'https://jwc.zjxu.edu.cn/list.jsp?urltype=tree.TreeTempUrl&wbtreeid=1046',
        ),
        isFalse,
      );
      expect(urlHasCasTicket(''), isFalse);
      expect(
        urlHasCasTicket('https://example.com/page?ticket=not-a-cas-ticket'),
        isFalse,
      );
    });
  });

  group('Unified auth login html detection', () {
    test('detects CAS login form markup', () {
      expect(
        looksLikeUnifiedAuthLoginHtml('''
          <html>
            <form id="fm1">
              <input type="hidden" name="lt" value="LT-1" />
              <input type="hidden" name="execution" value="e1s1" />
            </form>
          </html>
        '''),
        isTrue,
      );
    });

    test('ignores downstream service html', () {
      expect(
        looksLikeUnifiedAuthLoginHtml('<html><body>欢迎进入服务大厅</body></html>'),
        isFalse,
      );
    });
  });

  group('Unified auth login result parsing', () {
    test('accepts a WebVPN service redirect carrying a CAS ticket', () {
      expect(
        UnifiedAuthService.instance.isLoginSuccess(
          302,
          'https://webvpn.zjxu.edu.cn/login?cas_login=true&ticket=ST-1-test',
          '',
        ),
        isTrue,
      );
    });

    test('rejects a WebVPN redirect without a CAS ticket', () {
      expect(
        UnifiedAuthService.instance.isLoginSuccess(
          302,
          'https://webvpn.zjxu.edu.cn/login?cas_login=true',
          '',
        ),
        isFalse,
      );
    });

    test('prefers the real password error over captcha form labels', () {
      expect(
        UnifiedAuthService.instance.extractLoginFailureMessage(
          '<div>验证码</div><span>用户名或密码错误!</span>',
        ),
        '一卡通账号或密码错误，请检查后重试',
      );
    });

    test('recognizes an explicit captcha error', () {
      expect(
        UnifiedAuthService.instance.extractLoginFailureMessage(
          '<span>验证码错误!</span>',
        ),
        '验证码错误或已过期，请刷新后重试',
      );
    });
  });

  group('UnifiedAuthService session short-circuit', () {
    setUp(() {
      UnifiedAuthService.instance.debugReset();
    });

    test(
      'prepareLogin returns true immediately when session is active',
      () async {
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: '1234567890',
        );
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);

        final result = await UnifiedAuthService.instance.prepareLogin();
        expect(result, isTrue);
      },
    );

    test('isLoggedIn is false after debugReset', () {
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
    });

    test('debug session tracks account independently', () {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '00213544',
      );

      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(UnifiedAuthService.instance.currentAccount, '00213544');

      UnifiedAuthService.instance.debugReset();

      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(UnifiedAuthService.instance.currentAccount, isNull);
    });
  });

  group('UnifiedAuthService redirect chain', () {
    late Directory cookieDirectory;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      UnifiedAuthService.instance.debugReset();
      NetworkSettings.instance.debugReset();
      DioClient.instance.debugReset();
      cookieDirectory = await Directory.systemTemp.createTemp(
        'unified_auth_redirect_test_',
      );
      DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async {
        return '${cookieDirectory.path}/$folderName/';
      };
      await DioClient.instance.ensureInitialized();
    });

    tearDown(() async {
      UnifiedAuthService.instance.debugReset();
      DioClient.instance.debugReset();
      NetworkSettings.instance.debugReset();
      if (await cookieDirectory.exists()) {
        await cookieDirectory.delete(recursive: true);
      }
    });

    test('requests downstream ticket URL before confirming session', () async {
      const serviceUrl = 'https://webvpn.zjxu.edu.cn/login?cas_login=true';
      const ticketUrl =
          'https://webvpn.zjxu.edu.cn/login?cas_login=true&ticket=ST-1-test';
      final requestedUris = <Uri>[];
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/cas/login', (options) async {
          requestedUris.add(options.uri);
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [ticketUrl],
            },
          );
        })
        ..register('GET', '/login', (options) async {
          requestedUris.add(options.uri);
          return ResponseBody.fromString(
            '<html><body>WebVPN session ready</body></html>',
            200,
          );
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'test-account',
      );

      final result = await UnifiedAuthService.instance.validateSession(
        serviceUrl: serviceUrl,
        syncWebViewCookies: false,
      );

      expect(result, isTrue);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(
        requestedUris,
        contains(
          isA<Uri>()
              .having((uri) => uri.host, 'host', 'webvpn.zjxu.edu.cn')
              .having((uri) => uri.path, 'path', '/login')
              .having(
                (uri) => uri.queryParameters['ticket'],
                'ticket',
                'ST-1-test',
              ),
        ),
      );
      expect(adapter.requestLog, ['GET /cas/login', 'GET /login']);
    });
  });
}
