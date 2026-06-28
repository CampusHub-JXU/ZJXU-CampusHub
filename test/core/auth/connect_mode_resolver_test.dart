import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  test('resolve returns direct when direct reachable', () async {
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async => true;
    resolver.webVpnReachabilityChecker = () async => false;

    expect(await resolver.resolve(), ZhengfangMode.direct);
  });

  test(
    'resolve returns webVpn when direct fails but webvpn reachable',
    () async {
      final resolver = ConnectModeResolver.instance;
      resolver.directReachabilityChecker = () async => false;
      resolver.webVpnReachabilityChecker = () async => true;

      expect(await resolver.resolve(), ZhengfangMode.webVpn);
    },
  );

  test('resolve returns null when both unreachable', () async {
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async => false;
    resolver.webVpnReachabilityChecker = () async => false;

    expect(await resolver.resolve(), isNull);
  });

  test('resolve caches result within ttl and does not re-probe', () async {
    var directCalls = 0;
    var webVpnCalls = 0;
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async {
      directCalls++;
      return true;
    };
    resolver.webVpnReachabilityChecker = () async {
      webVpnCalls++;
      return false;
    };

    expect(await resolver.resolve(), ZhengfangMode.direct);
    expect(await resolver.resolve(), ZhengfangMode.direct);
    expect(directCalls, 1);
    expect(webVpnCalls, 0);
  });

  test('invalidate forces a fresh probe', () async {
    var directCalls = 0;
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async {
      directCalls++;
      return true;
    };
    resolver.webVpnReachabilityChecker = () async => false;

    await resolver.resolve();
    resolver.invalidate();
    await resolver.resolve();
    expect(directCalls, 2);
  });

  test('forceRefresh bypasses the cache', () async {
    var directCalls = 0;
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async {
      directCalls++;
      return true;
    };
    resolver.webVpnReachabilityChecker = () async => false;

    await resolver.resolve();
    await resolver.resolve(forceRefresh: true);
    expect(directCalls, 2);
  });
}
