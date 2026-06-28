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

  test(
    'ensureWebVpnGatewaySession returns true and stays direct when direct reachable',
    () async {
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
    },
  );

  test(
    'ensureWebVpnGatewaySession returns false when both unreachable',
    () async {
      await DioClient.instance.ensureInitialized();
      final resolver = ConnectModeResolver.instance;
      resolver.invalidate();
      resolver.directReachabilityChecker = () async => false;
      resolver.webVpnReachabilityChecker = () async => false;

      final result = await ZhengfangAuth.instance.ensureWebVpnGatewaySession(
        syncWebViewCookies: false,
      );

      expect(result, false);
    },
  );
}