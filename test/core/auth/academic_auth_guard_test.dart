import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    final resolver = ConnectModeResolver.instance;
    resolver.debugReset();
    resolver.directReachabilityChecker = () async => false;
    resolver.webVpnReachabilityChecker = () async => false;
  });

  tearDown(() {
    ZhengfangAuth.instance.debugReset();
    ConnectModeResolver.instance.debugReset();
    NetworkSettings.instance.debugReset();
  });

  Response<Map<String, dynamic>> okResponse() => Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 200,
        data: {'items': []},
      );

  Response<Map<String, dynamic>> redirectResponse() => Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 302,
        data: null,
      );

  test('passes through when first request is ok', () async {
    var calls = 0;
    final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
      authExpiredException: const _Marker(),
      request: () async {
        calls++;
        return okResponse();
      },
    );

    expect(resp.statusCode, 200);
    expect(calls, 1);
  });

  test('throws auth expired when 302 and recovery unavailable', () async {
    var calls = 0;
    await expectLater(
      AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        authExpiredException: const _Marker(),
        request: () async {
          calls++;
          return redirectResponse();
        },
      ),
      throwsA(isA<_Marker>()),
    );
    // 恢复失败，不重试。
    expect(calls, 1);
    expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
  });
}

class _Marker implements Exception {
  const _Marker();
}