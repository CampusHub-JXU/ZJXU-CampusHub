import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/route_failure.dart';
import 'package:jxu_campus_hub/core/network/route_gate.dart';

void main() {
  final resolver = ConnectModeResolver.instance;
  final target = Uri.parse('https://jwzx.zjxu.edu.cn/a');
  final sameOrigin = target.resolve('/b');
  late RouteGate gate;

  setUp(() {
    resolver.debugReset();
    gate = RouteGate();
  });
  tearDown(resolver.debugReset);

  test(
    'same origin waits for one gateway and reuses the ready lease',
    () async {
      var probes = 0;
      var gateways = 0;
      final started = Completer<void>();
      final release = Completer<void>();
      resolver.directVerdictChecker = (_) async {
        probes++;
        return RouteVerdict.webVpnRedirected;
      };
      Future<void> prepare(CancelToken _, DateTime deadline) async {
        gateways++;
        started.complete();
        await release.future;
      }

      final first = gate.acquire(
        target,
        sessionRevision: 7,
        prepareWebVpn: prepare,
      );
      await started.future;
      var finished = false;
      final second = gate
          .acquire(sameOrigin, sessionRevision: 7, prepareWebVpn: prepare)
          .then((lease) {
            finished = true;
            return lease;
          });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      release.complete();

      final lease = await first;
      expect(await second, same(lease));
      expect(
        await gate.acquire(target, sessionRevision: 7, prepareWebVpn: prepare),
        same(lease),
      );
      expect(lease.mode, ZhengfangMode.webVpn);
      expect(lease.sessionRevision, 7);
      expect(probes, 1);
      expect(gateways, 1);
    },
  );

  test('a separate origin proceeds while a gateway is pending', () async {
    final other = Uri.parse('https://mobilehall.zjxu.edu.cn/a');
    final release = Completer<void>();
    resolver.directVerdictChecker = (uri) async => uri.host == target.host
        ? RouteVerdict.webVpnRedirected
        : RouteVerdict.direct;
    final first = gate.acquire(target, prepareWebVpn: (_, _) => release.future);
    expect((await gate.acquire(other)).mode, ZhengfangMode.direct);
    release.complete();
    await first;
  });

  test('late gateway completion cannot replace an invalidated route', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    resolver.directVerdictChecker = (_) async => RouteVerdict.webVpnRedirected;
    final first = gate.acquire(
      target,
      prepareWebVpn: (_, _) async {
        started.complete();
        await release.future;
      },
    );
    await started.future;
    resolver.invalidate();
    resolver.directVerdictChecker = (_) async => RouteVerdict.direct;
    final second = gate.acquire(sameOrigin);
    release.complete();
    expect((await second).mode, ZhengfangMode.direct);
    expect((await first).mode, ZhengfangMode.direct);
  });

  test(
    'concurrent callers share one reverse probe and one direct lease',
    () async {
      var probes = 0;
      resolver.directVerdictChecker = (_) async =>
          ++probes == 1 ? RouteVerdict.webVpnRedirected : RouteVerdict.direct;
      Future<void> fail(CancelToken token, DateTime deadline) async =>
          throw RouteFailure(RouteFailureReason.webVpnGatewayFailed);

      final leases = await Future.wait([
        gate.acquire(target, prepareWebVpn: fail),
        gate.acquire(sameOrigin, prepareWebVpn: fail),
      ]);
      expect(leases.first, same(leases.last));
      expect(leases.first.mode, ZhengfangMode.direct);
      expect(leases.first.didFallback, isTrue);
      expect(probes, 2);
      expect(await resolver.resolve(), ZhengfangMode.direct);
    },
  );

  test('cancelled waiter does not cancel a shared gateway', () async {
    resolver.directVerdictChecker = (_) async => RouteVerdict.webVpnRedirected;
    final cancel = CancelToken();
    final started = Completer<void>();
    final release = Completer<void>();
    late CancelToken shared;
    Future<void> prepare(CancelToken token, DateTime _) async {
      shared = token;
      started.complete();
      await release.future;
    }

    final first = gate.acquire(
      target,
      cancelToken: cancel,
      prepareWebVpn: prepare,
    );
    final second = gate.acquire(target, prepareWebVpn: prepare);
    final rejected = expectLater(first, throwsA(isA<DioException>()));
    await started.future;
    cancel.cancel();
    await rejected;
    expect(shared.isCancelled, isFalse);
    release.complete();
    expect((await second).mode, ZhengfangMode.webVpn);
  });
}
