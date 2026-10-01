import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async {
      final dir = await Directory.systemTemp.createTemp('dio_client_test_');
      return '${dir.path}/$folderName/';
    };
  });

  tearDown(() {
    DioClient.instance.debugReset();
    NetworkSettings.instance.debugReset();
  });

  test('ensureInitialized is idempotent', () async {
    await DioClient.instance.ensureInitialized();
    final dio = DioClient.instance.dio;
    final unifiedAuthDio = DioClient.instance.unifiedAuthDio;
    final cookieJar = DioClient.instance.zhengfangCookieJar;
    final unifiedAuthCookieJar = DioClient.instance.unifiedAuthCookieJar;

    await DioClient.instance.ensureInitialized();

    expect(identical(dio, DioClient.instance.dio), isTrue);
    expect(
      identical(unifiedAuthDio, DioClient.instance.unifiedAuthDio),
      isTrue,
    );
    expect(identical(cookieJar, DioClient.instance.zhengfangCookieJar), isTrue);
    expect(
      identical(unifiedAuthCookieJar, DioClient.instance.unifiedAuthCookieJar),
      isTrue,
    );
    expect(identical(dio, unifiedAuthDio), isFalse);
    expect(identical(cookieJar, unifiedAuthCookieJar), isFalse);
  });

  test(
    'listens once and rebuilds both adapters without force-closing',
    () async {
      await DioClient.instance.ensureInitialized();
      expect(DioClient.instance.debugHasProxyModeListener, isTrue);

      final zhengfangProbe = _CloseProbeAdapter();
      final unifiedProbe = _CloseProbeAdapter();
      final zhengfangBefore = DioClient.instance.dio.httpClientAdapter;
      final unifiedBefore = DioClient.instance.unifiedAuthDio.httpClientAdapter;
      DioClient.instance.dio.httpClientAdapter = zhengfangProbe;
      DioClient.instance.unifiedAuthDio.httpClientAdapter = unifiedProbe;

      await NetworkSettings.instance.setIgnoreSystemProxy(false);

      expect(zhengfangProbe.closed, isTrue);
      expect(zhengfangProbe.force, isFalse);
      expect(unifiedProbe.closed, isTrue);
      expect(unifiedProbe.force, isFalse);
      expect(
        identical(zhengfangProbe, DioClient.instance.dio.httpClientAdapter),
        isFalse,
      );
      expect(
        identical(
          unifiedProbe,
          DioClient.instance.unifiedAuthDio.httpClientAdapter,
        ),
        isFalse,
      );
      expect(
        identical(zhengfangBefore, DioClient.instance.dio.httpClientAdapter),
        isFalse,
      );
      expect(
        identical(
          unifiedBefore,
          DioClient.instance.unifiedAuthDio.httpClientAdapter,
        ),
        isFalse,
      );
      expect(DioClient.instance.debugHasProxyModeListener, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('ignore_system_proxy'), isFalse);
    },
  );

  test('applies current setting when initialized after a toggle', () async {
    await NetworkSettings.instance.setIgnoreSystemProxy(false);
    await DioClient.instance.ensureInitialized();
    final created = DioClient.instance.dio.httpClientAdapter;
    final unifiedCreated = DioClient.instance.unifiedAuthDio.httpClientAdapter;

    await NetworkSettings.instance.setIgnoreSystemProxy(true);

    expect(
      identical(created, DioClient.instance.dio.httpClientAdapter),
      isFalse,
    );
    expect(
      identical(
        unifiedCreated,
        DioClient.instance.unifiedAuthDio.httpClientAdapter,
      ),
      isFalse,
    );
  });

  test('debugReset drops the proxy listener', () async {
    await DioClient.instance.ensureInitialized();
    expect(DioClient.instance.debugHasProxyModeListener, isTrue);

    var notifications = 0;
    void listener() => notifications++;
    NetworkSettings.instance.ignoreSystemProxy.addListener(listener);
    addTearDown(
      () => NetworkSettings.instance.ignoreSystemProxy.removeListener(listener),
    );

    DioClient.instance.debugReset();
    await NetworkSettings.instance.setIgnoreSystemProxy(false);

    expect(DioClient.instance.debugHasProxyModeListener, isFalse);
    expect(notifications, 1);
  });
}

class _CloseProbeAdapter implements HttpClientAdapter {
  bool closed = false;
  bool? force;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {
    closed = true;
    this.force = force;
  }
}
