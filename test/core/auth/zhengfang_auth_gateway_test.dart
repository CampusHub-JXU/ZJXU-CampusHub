import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

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

  test(
    'ensureWebVpnGatewaySessionResult forceWebVpn overrides direct reachability',
    () async {
      await DioClient.instance.ensureInitialized();
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      final resolver = ConnectModeResolver.instance;
      resolver.invalidate();
      resolver.directReachabilityChecker = () async => true;
      resolver.targetDirectReachabilityChecker = (_) async => true;
      resolver.webVpnReachabilityChecker = () async => true;

      final forced = await ZhengfangAuth.instance
          .ensureWebVpnGatewaySessionResult(
            syncWebViewCookies: false,
            targetUrl: 'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing',
            forceWebVpn: true,
          );

      // 忽略直连提前返回，进入 WebVPN 分支（网关校验结果视网络而定）。
      expect(forced.selectedMode, ZhengfangMode.webVpn);
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.webVpn);
    },
  );

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
}
