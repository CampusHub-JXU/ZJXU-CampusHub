import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    test(
      'unreachable gateway preserves cached balance and skips target CAS',
      () async {
        service.debugSetCachedBalance(23.5);
        ZhengfangAuth.instance.debugSetSession(
          active: true,
          studentId: '20250001',
        );
        ConnectModeResolver.instance.directReachabilityChecker = () async =>
            true;
        ConnectModeResolver.instance.targetDirectReachabilityChecker = (
          _,
        ) async => false;
        ConnectModeResolver.instance.webVpnReachabilityChecker = () async =>
            false;
        UnifiedAuthService.instance.debugSessionValidator = (_) async =>
            fail('target CAS must wait for gateway');
        expect(await service.fetchBalance(forceRefresh: true), isNull);
        expect(service.cachedBalance, 23.5);
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
        expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      },
    );

    test('unknown target session preserves cached balance', () async {
      service.debugSetCachedBalance(23.5);
      UnifiedAuthService.instance.debugSessionValidator = (_) async => null;
      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, 23.5);
    });

    test('explicitly expired target session clears cached balance', () async {
      service.debugSetCachedBalance(23.5);
      UnifiedAuthService.instance.debugSessionValidator = (_) async => false;
      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, isNull);
    });
  });

  group('CampusCardService.parseBalanceFromPageText', () {
    test('parses amount from same line with currency sign', () {
      final balance = service.parseBalanceFromPageText('卡内余额：￥23.50 元');

      expect(balance, 23.5);
    });

    test('parses amount near balance label on adjacent line', () {
      final balance = service.parseBalanceFromPageText('''
校园卡信息
18.25 元
卡内余额
''');

      expect(balance, 18.25);
    });

    test('returns null when no balance text exists', () {
      final balance = service.parseBalanceFromPageText('当前页面没有余额字段');

      expect(balance, isNull);
    });

    test('parses balance directly from returned html', () {
      final balance = service.parseBalanceFromHtml('''
        <html><body><section><span>卡内余额</span><strong>￥36.80</strong></section></body></html>
      ''');

      expect(balance, 36.8);
    });

    test('returns null when returned html is only a report shell', () {
      final balance = service.parseBalanceFromHtml('''
        <html><head><script src="report.js"></script></head><body><div id="app"></div></body></html>
      ''');

      expect(balance, isNull);
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

    test(
      'stops quietly when the rendered page is released during polling',
      () async {
        var finishCalls = 0;
        var cancelled = false;

        await service.debugPollRenderedBalance(
          evaluate: () {
            cancelled = true;
            return Future<String?>.error(StateError('webview disposed'));
          },
          finish: (_) async => finishCalls++,
          isCancelled: () => cancelled,
        );

        expect(finishCalls, 0);
      },
    );
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
