import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
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

/// 可挂起的 gateway：用于验证请求完成前持久身份变化 / 切换账号时的行为。
class _CompleterGateway implements Epay100Gateway {
  _CompleterGateway({this.body, this.error});

  final String? body;
  final Object? error;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<String> call(String method, Map<String, String> data) async {
    if (!started.isCompleted) started.complete();
    await release.future;
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

Future<void> waitFor(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition not met in time');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();

  final service = CampusCardService.instance;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    UnifiedAuthService.instance.debugReset();
    service.debugReset();
  });

  Future<int> durableEpoch() async =>
      (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.unified,
      )).epoch;

  Future<int> loginUnified(String account) async {
    UnifiedAuthService.instance.debugSetSession(active: true, account: account);
    await CredentialStore.instance.saveUnifiedAuthSession(account);
    // 刷新服务内“当前有效 durable epoch”（无记录时仅记录 epoch）。
    await service.restoreBalance();
    return durableEpoch();
  }

  Future<void> seedEnvelope({
    required String owner,
    required int epoch,
    required DateTime savedAt,
    Object? payload,
  }) async {
    final store = SecureStoragePrivateCacheStore(CampusCardService.cacheKey);
    await store.write(
      PrivateCacheEnvelope(
        owner: owner,
        updatedAt: savedAt,
        epoch: epoch,
        payload: payload ?? 36.8,
      ),
    );
  }

  Future<void> seedLegacy({
    required DateTime savedAt,
    String? owner,
    Object? payload,
  }) async {
    const storage = FlutterSecureStorage();
    await storage.write(
      key: 'zjxu_campus_card_balance',
      value: (payload ?? 36.8).toString(),
    );
    await storage.write(
      key: 'zjxu_campus_card_balance_updated_at',
      value: savedAt.toIso8601String(),
    );
    if (owner != null) {
      await storage.write(key: 'zjxu_campus_card_balance_owner', value: owner);
    }
  }

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
    setUp(() async {
      await loginUnified('casuser');
    });

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

    test('session unavailable clears the current account balance', () async {
      service.updateCachedBalance(23.5);
      expect(service.cachedBalance, 23.5);
      service.debugGateway = _FakeGateway(
        error: const EpaySessionUnavailableException(),
      );

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });

    test('gateway failure preserves cached balance', () async {
      service.updateCachedBalance(23.5);
      final updatedAt = service.lastUpdated;
      service.debugGateway = _FakeGateway(
        error: const EpayGatewayException('一卡通网关暂时无法响应，请稍后重试'),
      );

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, 23.5);
      expect(service.lastUpdated, updatedAt);
    });

    test('binding required preserves cached balance', () async {
      service.updateCachedBalance(23.5);
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
      await waitFor(() => calls == 1);

      completer.complete(null);
      expect(await Future.wait([first, second]), [null, null]);
      expect(calls, 1);
    });

    test(
      'failed refresh preserves old balance without reporting success',
      () async {
        service.updateCachedBalance(23.5);
        final updatedAt = service.lastUpdated;
        service.debugBalanceFetcher = () async => null;
        expect(await service.fetchBalance(forceRefresh: true), isNull);
        expect(service.cachedBalance, 23.5);
        expect(service.lastUpdated, updatedAt);
      },
    );

    test('clears cached balance when refresh cannot reach balance page', () {
      service.updateCachedBalance(23.5);

      expect(service.clearCachedBalance(), isNull);
      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });

    test(
      'serviceUnavailable sets lastBalanceFailure and preserves cached balance',
      () async {
        service.updateCachedBalance(23.5);
        final updatedAt = service.lastUpdated;
        service.debugGateway = _FakeGateway(
          error: const EpayGatewayException(
            'MH904接口：HTTP接口[open.ykt.getBalance]网络繁忙，请稍后再试',
          ),
        );

        expect(await service.fetchBalance(forceRefresh: true), isNull);
        expect(
          service.lastBalanceFailure,
          BalanceFailureKind.serviceUnavailable,
        );
        expect(service.cachedBalance, 23.5);
        expect(service.lastUpdated, updatedAt);
      },
    );

    test(
      'authExpired sets lastBalanceFailure and clears cached balance',
      () async {
        service.updateCachedBalance(23.5);
        service.debugGateway = _FakeGateway(
          error: const EpaySessionUnavailableException(),
        );

        expect(await service.fetchBalance(forceRefresh: true), isNull);
        expect(service.lastBalanceFailure, BalanceFailureKind.authExpired);
        expect(service.cachedBalance, isNull);
        expect(service.lastUpdated, isNull);
      },
    );

    test(
      'network failure sets lastBalanceFailure and preserves cached balance',
      () async {
        service.updateCachedBalance(23.5);
        final updatedAt = service.lastUpdated;
        service.debugGateway = _FakeGateway(
          error: const SocketException('Connection refused'),
        );

        expect(await service.fetchBalance(forceRefresh: true), isNull);
        expect(service.lastBalanceFailure, BalanceFailureKind.network);
        expect(service.cachedBalance, 23.5);
        expect(service.lastUpdated, updatedAt);
      },
    );

    test('successful fetch resets lastBalanceFailure to none', () async {
      service.debugGateway = _FakeGateway(
        error: const EpayGatewayException('ERR4995'),
      );
      await service.fetchBalance(forceRefresh: true);
      expect(service.lastBalanceFailure, BalanceFailureKind.serviceUnavailable);

      service.debugGateway = _FakeGateway(body: _balanceEnvelope(50.0));
      expect(await service.fetchBalance(forceRefresh: true), 50.0);
      expect(service.lastBalanceFailure, BalanceFailureKind.none);
      expect(service.cachedBalance, 50.0);
    });
  });

  group('campus card owner gating', () {
    test('no explicit CAS owner means zero request and no write', () async {
      final gateway = _FakeGateway(body: _balanceEnvelope(50));
      service.debugGateway = gateway;

      expect(await service.fetchBalance(), isNull);
      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(gateway.calls, isEmpty);

      service.updateCachedBalance(50);
      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });

    test('in-memory identity without durable session fails closed', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      final gateway = _FakeGateway(body: _balanceEnvelope(50));
      service.debugGateway = gateway;

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(gateway.calls, isEmpty);
    });

    test('owner-less in-memory balance is not visible', () {
      service.debugSetCachedBalance(23.5, updatedAt: DateTime.now());

      expect(service.cachedBalance, isNull);
    });

    test('logout clears the in-memory cache', () async {
      await loginUnified('A');
      service.updateCachedBalance(23.5);
      expect(service.cachedBalance, 23.5);

      await UnifiedAuthService.instance.markLoggedOut();

      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });

    test(
      'switching account hides the previous account in-memory cache',
      () async {
        await loginUnified('A');
        service.updateCachedBalance(23.5);
        expect(service.cachedBalance, 23.5);

        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');

        expect(service.cachedBalance, isNull);
      },
    );

    test(
      'session-unavailable from an old request does not clear the new account',
      () async {
        await loginUnified('A');
        service.updateCachedBalance(11.0);
        expect(service.cachedBalance, 11.0);

        final gateway = _CompleterGateway(
          error: const EpaySessionUnavailableException(),
        );
        service.debugGateway = gateway;
        final future = service.fetchBalance(forceRefresh: true);
        await gateway.started.future;

        // 请求完成前切换到 B 并写入 B 的余额。
        await loginUnified('B');
        service.updateCachedBalance(22.0);
        expect(service.cachedBalance, 22.0);

        gateway.release.complete();

        expect(await future, isNull);
        expect(service.cachedBalance, 22.0);
      },
    );

    test(
      'durable revoke during in-flight gateway request discards result',
      () async {
        await loginUnified('A');
        final gateway = _CompleterGateway(body: _balanceEnvelope(50));
        service.debugGateway = gateway;

        final future = service.fetchBalance(forceRefresh: true);
        await gateway.started.future;

        await AuthSessionPersistence.instance.revoke(
          CredentialSessionDomain.unified,
        );
        gateway.release.complete();

        expect(await future, isNull);
        expect(service.cachedBalance, isNull);
        final store = SecureStoragePrivateCacheStore(
          CampusCardService.cacheKey,
        );
        expect(await store.read(), isNull);
      },
    );
  });

  group('campus card cache ownership and TTL', () {
    const balanceKey = 'zjxu_campus_card_balance';
    const ownerKey = 'zjxu_campus_card_balance_owner';
    const updatedAtKey = 'zjxu_campus_card_balance_updated_at';

    test('restore restores only the current durable epoch + owner', () async {
      final epoch = await loginUnified('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());

      await service.restoreBalance();

      expect(service.cachedBalance, 36.8);
      expect(service.isStale, isFalse);
    });

    test('restore without an explicit account does not restore', () async {
      await seedEnvelope(owner: 'A', epoch: 1, savedAt: DateTime.now());

      await service.restoreBalance();

      expect(service.cachedBalance, isNull);
    });

    test('restore with an old durable epoch is not shown', () async {
      final epoch = await loginUnified('A');
      await seedEnvelope(owner: 'A', epoch: epoch, savedAt: DateTime.now());
      await service.restoreBalance();
      expect(service.cachedBalance, 36.8);

      await CredentialStore.instance.saveUnifiedAuthSession('A');
      service.debugReset();

      await service.restoreBalance();

      expect(service.cachedBalance, isNull);
    });

    test('restore completing after same-account re-login does not adopt old record', () async {
      final epoch = await loginUnified('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now(),
        payload: 36.8,
      );

      // 锁前推进 epoch：读取到旧 epoch 后同账号登出再登录（E -> E+2）。
      service.debugRestoreBarrier = () async {
        await UnifiedAuthService.instance.markLoggedOut();
        await CredentialStore.instance.saveUnifiedAuthSession('A');
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      };

      await service.restoreBalance();

      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });

    test(
      'getter returns null after same-account re-login without new fetch',
      () async {
        final epoch = await loginUnified('A');
        await seedEnvelope(
          owner: 'A',
          epoch: epoch,
          savedAt: DateTime.now(),
          payload: 36.8,
        );
        await service.restoreBalance();
        expect(service.cachedBalance, 36.8);

        // 同账号登出再登录：监听同步失效内存，getter 不暴露旧 epoch 记录。
        await UnifiedAuthService.instance.markLoggedOut();
        await CredentialStore.instance.saveUnifiedAuthSession('A');
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');

        expect(service.cachedBalance, isNull);
        expect(service.lastUpdated, isNull);
      },
    );

    test(
      'stale in-memory record is dropped once a new durable epoch is observed',
      () async {
        final epoch = await loginUnified('A');
        await seedEnvelope(
          owner: 'A',
          epoch: epoch,
          savedAt: DateTime.now(),
          payload: 36.8,
        );
        await service.restoreBalance();
        expect(service.cachedBalance, 36.8);

        // 同账号重登推进 epoch 但无 notify；下一次 durable 读取必须失效旧记录。
        await CredentialStore.instance.saveUnifiedAuthSession('A');
        await service.restoreBalance();
        expect(service.cachedBalance, isNull);
      },
    );

    test('legacy balance without owner is discarded, not migrated', () async {
      await loginUnified('A');
      await seedLegacy(savedAt: DateTime.now());

      await service.restoreBalance();

      expect(service.cachedBalance, isNull);
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: balanceKey), isNull);
      expect(await storage.read(key: updatedAtKey), isNull);
      final store = SecureStoragePrivateCacheStore(CampusCardService.cacheKey);
      expect(await store.read(), isNull);
    });

    test('legacy balance with owner is discarded (no epoch proof)', () async {
      await loginUnified('A');
      await seedLegacy(owner: 'A', savedAt: DateTime.now());

      await service.restoreBalance();

      expect(service.cachedBalance, isNull);
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: balanceKey), isNull);
      expect(await storage.read(key: ownerKey), isNull);
      final store = SecureStoragePrivateCacheStore(CampusCardService.cacheKey);
      expect(await store.read(), isNull);
    });

    test('another account balance is never shown as current', () async {
      await loginUnified('B');
      await seedEnvelope(owner: 'A', epoch: 1, savedAt: DateTime.now());

      await service.restoreBalance();

      expect(service.cachedBalance, isNull);
    });

    test('fresh cache is served without calling the gateway', () async {
      final epoch = await loginUnified('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now(),
        payload: 23.5,
      );
      await service.restoreBalance();
      final gateway = _FakeGateway(body: _balanceEnvelope(50));
      service.debugGateway = gateway;

      expect(await service.fetchBalance(), 23.5);
      expect(gateway.calls, isEmpty);
    });

    test('expired cache triggers a gateway refresh', () async {
      final epoch = await loginUnified('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now().subtract(const Duration(minutes: 6)),
        payload: 23.5,
      );
      await service.restoreBalance();
      expect(service.isStale, isTrue);
      final gateway = _FakeGateway(body: _balanceEnvelope(50));
      service.debugGateway = gateway;

      expect(await service.fetchBalance(), 50);
      expect(gateway.calls, hasLength(1));
      expect(service.cachedBalance, 50);
    });

    test('forceRefresh bypasses a fresh cache', () async {
      final epoch = await loginUnified('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now(),
        payload: 23.5,
      );
      await service.restoreBalance();
      final gateway = _FakeGateway(body: _balanceEnvelope(50));
      service.debugGateway = gateway;

      expect(await service.fetchBalance(forceRefresh: true), 50);
      expect(gateway.calls, hasLength(1));
    });

    test('network failure keeps the same-account balance', () async {
      final epoch = await loginUnified('A');
      await seedEnvelope(
        owner: 'A',
        epoch: epoch,
        savedAt: DateTime.now(),
        payload: 23.5,
      );
      await service.restoreBalance();
      service.debugGateway = _FakeGateway(
        error: const EpayGatewayException('一卡通网关暂时无法响应，请稍后重试'),
      );

      expect(await service.fetchBalance(forceRefresh: true), isNull);
      expect(service.cachedBalance, 23.5);
    });

    test('late result is dropped after same-account re-login', () async {
      await loginUnified('A');
      final completer = Completer<double?>();
      service.debugBalanceFetcher = () => completer.future;

      final future = service.fetchBalance(forceRefresh: true);
      await Future<void>.delayed(Duration.zero);

      // 同账号登出再登录：纪元推进，旧请求结果必须丢弃。
      await UnifiedAuthService.instance.markLoggedOut();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');

      completer.complete(42.0);

      expect(await future, isNull);
      expect(service.cachedBalance, isNull);
    });

    test('non-force shares an in-flight force request', () async {
      await loginUnified('A');
      final completer = Completer<double?>();
      var calls = 0;
      service.debugBalanceFetcher = () {
        calls += 1;
        return completer.future;
      };

      final forced = service.fetchBalance(forceRefresh: true);
      final nonForce = service.fetchBalance();
      await waitFor(() => calls == 1);

      completer.complete(33.0);

      expect(await forced, 33.0);
      expect(await nonForce, 33.0);
      expect(calls, 1);
      expect(service.cachedBalance, 33.0);
    });

    test(
      'force starts a newer request; stale non-force cannot overwrite',
      () async {
        await loginUnified('A');
        final slow = Completer<double?>();
        final fast = Completer<double?>();
        var calls = 0;
        service.debugBalanceFetcher = () {
          calls += 1;
          return calls == 1 ? slow.future : fast.future;
        };

        final nonForce = service.fetchBalance();
        final forced = service.fetchBalance(forceRefresh: true);
        await waitFor(() => calls == 2);
        expect(calls, 2);

        slow.complete(11.0);
        expect(await nonForce, isNull);

        fast.complete(22.0);
        expect(await forced, 22.0);
        expect(service.cachedBalance, 22.0);
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
