import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

import '../../helpers/mock_http_client_adapter.dart';

/// 严格命中 [looksLikeZhengfangLoginHtml] 的正方登录页 fixture。
const String _loginHtml =
    '<html><form action="/jwglxt/xtgl/login_slogin.html">'
    '<input id="yhm" name="yhm" />'
    '<input id="mm" name="mm" />'
    '</form></html>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async {
      final dir = await Directory.systemTemp.createTemp('zf_webvpn_test_');
      return '${dir.path}/$folderName/';
    };
  });

  tearDown(() {
    ZhengfangAuth.instance.setMode(ZhengfangMode.direct);
    ZhengfangAuth.instance.debugReset();
    ConnectModeResolver.instance.debugReset();
    DioClient.instance.debugReset();
    NetworkSettings.instance.debugReset();
  });

  test('ensureWebVpnGatewaySession returns true and stays direct when direct reachable', () async {
    await DioClient.instance.ensureInitialized();
    ZhengfangAuth.instance.setMode(ZhengfangMode.webVpn);
    final resolver = ConnectModeResolver.instance;
    resolver.invalidate();
    resolver.directReachabilityChecker = () async => true;
    resolver.webVpnReachabilityChecker = () async => false;

    final result = await ZhengfangAuth.instance.ensureWebVpnGatewaySession(
      syncWebViewCookies: false,
    );

    expect(result, true);
    expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
  });

  test(
    'ensureWebVpnGatewaySession returns unknown when both unreachable',
    () async {
      await DioClient.instance.ensureInitialized();
      final resolver = ConnectModeResolver.instance;
      resolver.invalidate();
      resolver.directReachabilityChecker = () async => false;
      resolver.webVpnReachabilityChecker = () async => false;

      final result = await ZhengfangAuth.instance.ensureWebVpnGatewaySession(
        syncWebViewCookies: false,
      );

      expect(result, isNull);
    },
  );

  test(
    'ensureWebVpnGatewaySessionResult uses targetUrl not jwzx reachability',
    () async {
      await DioClient.instance.ensureInitialized();
      ZhengfangAuth.instance.setMode(ZhengfangMode.webVpn);
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      final resolver = ConnectModeResolver.instance;
      resolver.invalidate();
      resolver.directReachabilityChecker = () async => false;
      resolver.targetDirectReachabilityChecker = (_) async => true;
      resolver.webVpnReachabilityChecker = () async => true;

      final byTarget = await ZhengfangAuth.instance
          .ensureWebVpnGatewaySessionResult(
            syncWebViewCookies: false,
            targetUrl: 'https://mobilehall.zjxu.edu.cn/ykt',
          );
      expect(byTarget.ready, true);
      expect(byTarget.selectedMode, ZhengfangMode.direct);
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    },
  );

  test('ensureWebVpnGatewaySessionResult forceWebVpn overrides direct reachability', () async {
    await DioClient.instance.ensureInitialized();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250001');
    final resolver = ConnectModeResolver.instance;
    resolver.invalidate();
    resolver.directReachabilityChecker = () async => true;
    resolver.targetDirectReachabilityChecker = (_) async => true;
    resolver.webVpnReachabilityChecker = () async => true;

    final forced = await ZhengfangAuth.instance
        .ensureWebVpnGatewaySessionResult(
          syncWebViewCookies: false,
          targetUrl:
              'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing',
          forceWebVpn: true,
        );

    // 忽略直连提前返回，进入 WebVPN 分支（网关校验结果视网络而定）。
    expect(forced.selectedMode, ZhengfangMode.webVpn);
    // 全局模式只在网关会话建成后切换；未建成时保持发起前的直连。
    expect(
      ZhengfangAuth.instance.mode,
      forced.ready == true ? ZhengfangMode.webVpn : ZhengfangMode.direct,
    );
  });

  test(
    'ensureWebVpnGatewaySessionResult null does not log out zhengfang',
    () async {
      await DioClient.instance.ensureInitialized();
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      final resolver = ConnectModeResolver.instance;
      resolver.invalidate();
      resolver.directReachabilityChecker = () async => true;
      resolver.targetDirectReachabilityChecker = (_) async => false;
      resolver.webVpnReachabilityChecker = () async => false;

      final result = await ZhengfangAuth.instance
          .ensureWebVpnGatewaySessionResult(
            syncWebViewCookies: false,
            targetUrl: 'https://mobilehall.zjxu.edu.cn/ykt',
          );

      expect(result.ready, isNull);
      expect(result.selectedMode, isNull);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    },
  );

  group('validateSession 的 owner/revision 边界', () {
    test('失效探测记录状态、Cookie 名称和指纹，隐藏所有凭据', () async {
      await DioClient.instance.ensureInitialized();
      final uri = Uri.parse(
        'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html',
      );
      await DioClient.instance.zhengfangCookieJar.saveFromResponse(uri, [
        Cookie('JSESSIONID', 'private-request-value')..path = '/jwglxt',
      ]);
      DioClient.instance.dio.httpClientAdapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          uri.path,
          '',
          statusCode: 302,
          headers: {
            'location': [
              '/jwglxt/xtgl/login_slogin.html;jsessionid=private-matrix-value'
                  '?ticket=private-ticket-value',
            ],
            'set-cookie': ['route=private-response-value; Path=/'],
          },
        );
      final auth = ZhengfangAuth.instance;
      auth.debugSetSession(active: true, studentId: 'A');

      expect(
        await auth.validateSession(
          revokeOnInvalid: false,
          caller: 'academic_guard',
        ),
        isFalse,
      );
      final log = AppLogger.instance.authTrail.last.message;
      expect(
        log,
        contains('caller=academic_guard outcome=invalid reason=redirected'),
      );
      expect(
        log,
        contains('statusCode=302 locationPath=/jwglxt/xtgl/login_slogin.html'),
      );
      expect(log, contains('cookieNames=[JSESSIONID] cookieCount=1'));
      expect(log, matches(RegExp(r'cookieFingerprint=[0-9a-f]{8} ')));
      expect(log, contains('setCookieNames=[route]'));
      expect(log, isNot(contains('private-')));
      expect(auth.isLoggedIn, isTrue);
    });

    test('探测命中失效且会话未变：返回 false 并登出', () async {
      await DioClient.instance.ensureInitialized();
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/jwglxt/xtgl/index_initMenu.html', (options) async {
          return ResponseBody.fromString(
            _loginHtml,
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
            },
          );
        });
      DioClient.instance.dio.httpClientAdapter = adapter;
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      // 真实已登录会话必有匹配的持久 envelope，条件撤销才能命中。
      final committed = await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.academic,
        account: 'A',
        expectedEpoch: 0,
      );
      expect(committed, isNotNull);

      final result = await ZhengfangAuth.instance.validateSession();

      expect(result, isFalse);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
    });

    test('探测期间切号到 B：旧失效响应不登出 B，返回 null', () async {
      await DioClient.instance.ensureInitialized();
      final gate = Completer<void>();
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/jwglxt/xtgl/index_initMenu.html', (options) async {
          await gate.future;
          return ResponseBody.fromString(
            _loginHtml,
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
            },
          );
        });
      DioClient.instance.dio.httpClientAdapter = adapter;
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');

      final pending = ZhengfangAuth.instance.validateSession();
      await Future<void>.delayed(Duration.zero);
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'B');
      gate.complete();

      final result = await pending;
      expect(result, isNull, reason: '会话已变化时不下失效结论');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'B');
    });
  });
}
