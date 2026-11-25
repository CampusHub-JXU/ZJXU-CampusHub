import 'dart:async';

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

  test('jwzx direct does not force card onto direct', () async {
    var jwzxCalls = 0;
    var cardCalls = 0;
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async {
      jwzxCalls++;
      return true;
    };
    resolver.targetDirectReachabilityChecker = (url) async {
      cardCalls++;
      expect(url, contains('mobilehall.zjxu.edu.cn'));
      return false;
    };
    resolver.webVpnReachabilityChecker = () async => true;

    expect(await resolver.resolve(), ZhengfangMode.direct);
    expect(
      await resolver.resolve(
        targetUrl: 'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form',
      ),
      ZhengfangMode.webVpn,
    );
    expect(jwzxCalls, 1);
    expect(cardCalls, 1);
  });

  test('card direct is not blocked by jwzx unreachability', () async {
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async => false;
    resolver.targetDirectReachabilityChecker = (_) async => true;
    resolver.webVpnReachabilityChecker = () async => true;

    expect(await resolver.resolve(), ZhengfangMode.webVpn);
    expect(
      await resolver.resolve(targetUrl: 'https://mobilehall.zjxu.edu.cn/ykt'),
      ZhengfangMode.direct,
    );
  });

  test('target cache is isolated by origin not path', () async {
    var cardCalls = 0;
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async => true;
    resolver.targetDirectReachabilityChecker = (_) async {
      cardCalls++;
      return true;
    };
    resolver.webVpnReachabilityChecker = () async => false;

    expect(
      await resolver.resolve(targetUrl: 'https://mobilehall.zjxu.edu.cn/a'),
      ZhengfangMode.direct,
    );
    expect(
      await resolver.resolve(targetUrl: 'https://mobilehall.zjxu.edu.cn/b#/x'),
      ZhengfangMode.direct,
    );
    expect(await resolver.resolve(), ZhengfangMode.direct);
    expect(cardCalls, 1);
  });

  test('same target coalesces inflight probes', () async {
    var cardCalls = 0;
    final started = Completer<void>();
    final release = Completer<bool>();
    final resolver = ConnectModeResolver.instance;
    resolver.targetDirectReachabilityChecker = (_) {
      cardCalls++;
      if (!started.isCompleted) started.complete();
      return release.future;
    };
    resolver.webVpnReachabilityChecker = () async => false;

    final first = resolver.resolve(
      targetUrl: 'https://mobilehall.zjxu.edu.cn/a',
    );
    await started.future;
    final second = resolver.resolve(
      targetUrl: 'https://mobilehall.zjxu.edu.cn/b',
    );
    release.complete(true);
    expect(await Future.wait([first, second]), [
      ZhengfangMode.direct,
      ZhengfangMode.direct,
    ]);
    expect(cardCalls, 1);
  });

  test('network change drops stale probe writes', () async {
    var probes = 0;
    final started = Completer<void>();
    final release = Completer<bool>();
    final resolver = ConnectModeResolver.instance;
    resolver.targetDirectReachabilityChecker = (_) {
      probes++;
      if (!started.isCompleted) started.complete();
      return release.future;
    };
    resolver.webVpnReachabilityChecker = () async => false;

    final stale = resolver.resolve(
      targetUrl: 'https://mobilehall.zjxu.edu.cn/ykt',
    );
    await started.future;
    resolver.invalidate();
    resolver.targetDirectReachabilityChecker = (_) async {
      probes++;
      return true;
    };

    final fresh = resolver.resolve(
      targetUrl: 'https://mobilehall.zjxu.edu.cn/ykt',
    );
    release.complete(false);
    expect(await stale, isNull);
    expect(await fresh, ZhengfangMode.direct);
    expect(
      await resolver.resolve(targetUrl: 'https://mobilehall.zjxu.edu.cn/ykt'),
      ZhengfangMode.direct,
    );
    expect(probes, 2);
  });

  test('null result is not cached', () async {
    var calls = 0;
    final resolver = ConnectModeResolver.instance;
    resolver.directReachabilityChecker = () async {
      calls++;
      return false;
    };
    resolver.webVpnReachabilityChecker = () async => false;

    expect(await resolver.resolve(), isNull);
    expect(await resolver.resolve(), isNull);
    expect(calls, 2);
  });

  test('CAS redirect is reachable and is not treated as authenticated', () {
    expect(
      ConnectModeResolver.classifyDirectReachable(
        statusCode: 302,
        location: 'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn%2Fykt',
        requestUri: Uri.parse('https://mobilehall.zjxu.edu.cn/ykt'),
      ),
      RouteVerdict.direct,
    );
  });

  test('webvpn redirect is not direct', () {
    expect(
      ConnectModeResolver.classifyDirectReachable(
        statusCode: 302,
        location: 'https://webvpn.zjxu.edu.cn/login',
        requestUri: Uri.parse('https://mobilehall.zjxu.edu.cn/ykt'),
      ),
      RouteVerdict.webVpnRedirected,
    );
  });

  test('unknown 3xx host is not treated as reachable', () {
    expect(
      ConnectModeResolver.classifyDirectReachable(
        statusCode: 302,
        location: 'https://evil.example/phish',
        requestUri: Uri.parse('https://mobilehall.zjxu.edu.cn/ykt'),
      ),
      RouteVerdict.unknownRedirect,
    );
  });

  test('business http including errors counts as reachable', () {
    final uri = Uri.parse('https://mobilehall.zjxu.edu.cn/ykt');
    expect(
      ConnectModeResolver.classifyDirectReachable(
        statusCode: 200,
        requestUri: uri,
      ),
      RouteVerdict.direct,
    );
    expect(
      ConnectModeResolver.classifyDirectReachable(
        statusCode: 403,
        requestUri: uri,
      ),
      RouteVerdict.direct,
    );
    expect(
      ConnectModeResolver.classifyDirectReachable(
        statusCode: 302,
        location: '/home',
        requestUri: uri,
      ),
      RouteVerdict.direct,
    );
  });

  test(
    'business observation supersedes a late probe for the same origin',
    () async {
      final resolver = ConnectModeResolver.instance;
      final target = Uri.parse(ZhengfangAuth.directAcademicServiceUrl);
      final release = Completer<RouteVerdict>();
      resolver.directVerdictChecker = (_) => release.future;
      final stale = resolver.resolve();
      resolver.markWebVpnRedirected(target);

      expect(await resolver.resolve(), ZhengfangMode.webVpn);
      release.complete(RouteVerdict.direct);
      expect(await stale, ZhengfangMode.direct);
      expect(
        await resolver.resolve(targetUrl: '$target'),
        ZhengfangMode.webVpn,
      );
    },
  );

  test(
    'unknown redirects are never cached, including when WebVPN is reachable',
    () async {
      final resolver = ConnectModeResolver.instance;
      var probes = 0;
      resolver.directVerdictChecker = (_) async {
        probes++;
        return RouteVerdict.unknownRedirect;
      };
      resolver.webVpnReachabilityChecker = () async => true;
      expect(await resolver.resolve(), ZhengfangMode.webVpn);
      expect(await resolver.resolve(), ZhengfangMode.webVpn);
      expect(probes, 2);
    },
  );
}
