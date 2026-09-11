import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeGateway implements Epay100Gateway {
  _FakeGateway({this.body, this.error});

  final String? body;
  final Object? error;
  final List<({String method, Map<String, String> data})> calls = [];

  @override
  Future<String> call(String method, Map<String, String> data) async {
    calls.add((method: method, data: Map<String, String>.of(data)));
    if (error != null) throw error!;
    return body!;
  }

  @override
  Future<void> invalidate() async {}

  @override
  void debugReset() {}
}

String _balanceEnvelope(Object? balance) => jsonEncode({
  'code': '200',
  'msg': 'SUC0000',
  'data': balance == null ? <String, dynamic>{} : {'balance': balance},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();

  final service = CampusCardService.instance;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    service.debugReset();
  });

  group('campus card session preparation', () {
    late Directory cookies;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      NetworkSettings.instance.debugReset();
      DioClient.instance.debugReset();
      UnifiedAuthService.instance.debugReset();
      ConnectModeResolver.instance.debugReset();
      cookies = await Directory.systemTemp.createTemp('campus_card_access_');
      DioClient.instance.debugCookieDirectoryPathProvider = (folder) async =>
          '${cookies.path}/$folder/';
      await DioClient.instance.ensureInitialized();
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'test',
      );
      ConnectModeResolver.instance.directReachabilityChecker = () async => true;
      ConnectModeResolver.instance.targetDirectReachabilityChecker = (
        _,
      ) async => true;
      ConnectModeResolver.instance.webVpnReachabilityChecker = () async =>
          false;
    });
    tearDown(() async {
      service.debugReset();
      UnifiedAuthService.instance.debugReset();
      ZhengfangAuth.instance.debugReset();
      ConnectModeResolver.instance.debugReset();
      DioClient.instance.debugReset();
      NetworkSettings.instance.debugReset();
      await cookies.delete(recursive: true);
    });

    test(
      'direct route validates target service before returning original URL',
      () async {
        final services = <String>[];
        UnifiedAuthService.instance.debugSessionValidator = (url) async {
          services.add(url);
          return true;
        };
        expect(
          await service.prepareStatusPage(),
          CampusCardService.statusPageUrl,
        );
        expect(services, [CasService.campusCardStatus.serviceUrl]);
        expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
      },
    );

    test(
      'jwzx unreachability does not hijack campus card direct URL',
      () async {
        ConnectModeResolver.instance.directReachabilityChecker = () async =>
            false;
        ConnectModeResolver.instance.webVpnReachabilityChecker = () async =>
            true;
        expect(
          await ConnectModeResolver.instance.resolve(),
          ZhengfangMode.webVpn,
        );
        UnifiedAuthService.instance.debugSessionValidator = (url) async {
          expect(url, CasService.campusCardStatus.serviceUrl);
          return true;
        };

        expect(
          await service.prepareStatusPage(),
          CampusCardService.statusPageUrl,
        );
        expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
      },
    );

    test('jwzx direct with card unreachable uses webvpn url', () async {
      ConnectModeResolver.instance.directReachabilityChecker = () async => true;
      ConnectModeResolver.instance.targetDirectReachabilityChecker = (
        _,
      ) async => false;
      ConnectModeResolver.instance.webVpnReachabilityChecker = () async => true;
      expect(
        await ConnectModeResolver.instance.resolve(),
        ZhengfangMode.direct,
      );
      final services = <String>[];
      UnifiedAuthService.instance.debugSessionValidator = (url) async {
        services.add(url);
        return true;
      };
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          _WebVpnPortalAdapter();

      expect(
        await service.prepareStatusPage(),
        ZhengfangAuth.instance.buildWebVpnProxyUrl(
          CampusCardService.statusPageUrl,
        ),
      );
      expect(services, [
        ZhengfangAuth.webVpnGatewayServiceUrl,
        CasService.campusCardStatus.serviceUrl,
      ]);
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.webVpn);
    });
  });

  group('campus card balance via epay100 gateway', () {
    test('fetches and caches balance from the cardService RPC', () async {
      final gateway = _FakeGateway(body: _balanceEnvelope(23.5));
      service.debugGateway = gateway;

      expect(await service.fetchBalance(forceRefresh: true), 23.5);
      expect(service.cachedBalance, 23.5);
      expect(gateway.calls.single.method, 'app.yktservice.getBalance');
      expect(gateway.calls.single.data, isEmpty);
    });

    test('parses a string balance field', () async {
      service.debugGateway = _FakeGateway(body: _balanceEnvelope('36.80'));

      expect(await service.fetchBalance(forceRefresh: true), 36.8);
    });

    test('missing balance field returns null without caching', () async {
      service.debugGateway = _FakeGateway(body: _balanceEnvelope(null));

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, isNull);
    });

    test('session unavailable clears cached balance', () async {
      service.debugSetCachedBalance(23.5, updatedAt: DateTime(2026, 9, 8));
      service.debugGateway = _FakeGateway(
        error: const EpaySessionUnavailableException(),
      );

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });

    test('gateway failure preserves cached balance', () async {
      final updatedAt = DateTime(2026, 9, 8);
      service.debugSetCachedBalance(23.5, updatedAt: updatedAt);
      service.debugGateway = _FakeGateway(
        error: const EpayGatewayException('一卡通网关暂时无法响应，请稍后重试'),
      );

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, 23.5);
      expect(service.lastUpdated, updatedAt);
    });

    test('binding required preserves cached balance', () async {
      service.debugSetCachedBalance(23.5);
      service.debugGateway = _FakeGateway(
        error: const EpayBindingRequiredException(),
      );

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, 23.5);
    });

    test('coalesces concurrent balance refreshes', () async {
      final completer = Completer<double?>();
      var calls = 0;
      service.debugBalanceFetcher = () {
        calls += 1;
        return completer.future;
      };

      final first = service.fetchBalance(forceRefresh: true);
      final second = service.fetchBalance(forceRefresh: true);
      expect(calls, 1);

      completer.complete(null);
      expect(await Future.wait([first, second]), [null, null]);
      expect(calls, 1);
    });

    test(
      'failed refresh preserves old balance without reporting success',
      () async {
        final updatedAt = DateTime(2026, 9, 8);
        service.debugSetCachedBalance(23.5, updatedAt: updatedAt);
        service.debugBalanceFetcher = () async => null;
        expect(await service.fetchBalance(forceRefresh: true), isNull);
        expect(service.cachedBalance, 23.5);
        expect(service.lastUpdated, updatedAt);
      },
    );

    test('clears cached balance when refresh cannot reach balance page', () {
      service.debugSetCachedBalance(23.5, updatedAt: DateTime(2026, 6, 28));

      expect(service.clearCachedBalance(), isNull);
      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });
  });
}

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) {
    return _FakePlatformCookieManager(params);
  }
}

class _FakePlatformCookieManager extends PlatformCookieManager {
  _FakePlatformCookieManager(super.params) : super.implementation();

  final Map<String, Cookie> _cookies = {};

  String _key(WebUri url, String name, String? domain, String path) {
    return '${url.host}|${domain ?? ''}|$path|$name';
  }

  @override
  Future<bool> setCookie({
    required WebUri url,
    required String name,
    required String value,
    String path = '/',
    String? domain,
    int? expiresDate,
    int? maxAge,
    bool? isSecure,
    bool? isHttpOnly,
    HTTPCookieSameSitePolicy? sameSite,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    _cookies[_key(url, name, domain, path)] = Cookie(
      name: name,
      value: value,
      domain: domain,
      path: path,
    );
    return true;
  }

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    return _cookies.values.toList(growable: false);
  }

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    _cookies.remove(_key(url, name, domain, path));
    return true;
  }
}

class _WebVpnPortalAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    options.path = 'https://webvpn.zjxu.edu.cn/user/index';
    return ResponseBody.fromString(
      '<html><body>webvpn portal</body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
