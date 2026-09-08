import 'dart:async';
import 'dart:io';

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
      'unreachable gateway preserves cached balance and skips target CAS',
      () async {
        service.debugSetCachedBalance(23.5);
        ConnectModeResolver.instance.directReachabilityChecker = () async =>
            false;
        UnifiedAuthService.instance.debugSessionValidator = (_) async =>
            fail('target CAS must wait for gateway');
        expect(await service.fetchBalance(forceRefresh: true), isNull);
        expect(service.cachedBalance, 23.5);
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
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
