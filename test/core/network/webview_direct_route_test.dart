import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:jxu_campus_hub/core/network/proxy_mode.dart';
import 'package:jxu_campus_hub/core/network/webview_direct_route.dart';

class _FakeBackend implements WebViewProxyBackend {
  _FakeBackend({this.supported = true, this.setThrows = false});

  bool supported;
  bool setThrows;
  final List<String> calls = <String>[];
  Completer<void>? setGate;

  @override
  Future<bool> isSupported() async {
    calls.add('supported');
    return supported;
  }

  @override
  Future<void> setDirect() async {
    calls.add('set');
    await setGate?.future;
    if (setThrows) throw StateError('boom');
  }

  @override
  Future<void> clear() async {
    calls.add('clear');
  }
}

int _count(_FakeBackend b, String name) =>
    b.calls.where((c) => c == name).length;

void main() {
  tearDown(() {
    debugSystemProxyLookup = null;
    NetworkSettings.instance.debugReset();
  });

  test('引用计数：acquire x2 -> set 一次；release x2 -> clear 一次', () async {
    final backend = _FakeBackend();
    final route = WebViewDirectRoute(backend: backend);

    final a = await route.acquire();
    final b = await route.acquire();
    expect(a.status, WebViewDirectRouteStatus.applied);
    expect(b.applied, isTrue);
    expect(_count(backend, 'set'), 1);

    await a.release();
    expect(_count(backend, 'clear'), 0, reason: '仍有租约存活，不得提前清除');
    expect(route.debugApplied, isTrue);

    await b.release();
    expect(_count(backend, 'clear'), 1);
    expect(route.debugApplied, isFalse);
    expect(route.debugLeaseCount, 0);
  });

  test('release 幂等：重复释放不会多减计数 / 多次 clear', () async {
    final backend = _FakeBackend();
    final route = WebViewDirectRoute(backend: backend);

    final a = await route.acquire();
    final b = await route.acquire();
    await a.release();
    await a.release();
    await a.release();
    expect(route.debugLeaseCount, 1);
    expect(_count(backend, 'clear'), 0);

    await b.release();
    await b.release();
    expect(_count(backend, 'clear'), 1);
  });

  test('释放后重新 acquire 会再次 set', () async {
    final backend = _FakeBackend();
    final route = WebViewDirectRoute(backend: backend);

    await (await route.acquire()).release();
    await (await route.acquire()).release();
    expect(_count(backend, 'set'), 2);
    expect(_count(backend, 'clear'), 2);
  });

  test('不支持：不抛异常、如实上报 unsupported，release 不 clear', () async {
    final backend = _FakeBackend(supported: false);
    final route = WebViewDirectRoute(backend: backend);

    final lease = await route.acquire();
    expect(lease.status, WebViewDirectRouteStatus.unsupported);
    expect(lease.applied, isFalse);
    expect(_count(backend, 'set'), 0);

    await lease.release();
    expect(_count(backend, 'clear'), 0);
    expect(route.debugLeaseCount, 0);
  });

  test('setDirect 抛异常：降级为 failed，不抛', () async {
    final backend = _FakeBackend(setThrows: true);
    final route = WebViewDirectRoute(backend: backend);

    final lease = await route.acquire();
    expect(lease.status, WebViewDirectRouteStatus.failed);
    await lease.release();
    expect(_count(backend, 'clear'), 1, reason: '失败的 set 可能部分生效，最后释放时保守 clear');
  });

  test('并发 acquire / release 串行：先设置完成再返回，set 只一次', () async {
    final backend = _FakeBackend()..setGate = Completer<void>();
    final route = WebViewDirectRoute(backend: backend);

    final f1 = route.acquire();
    final f2 = route.acquire();
    await Future<void>.delayed(Duration.zero);
    var done = false;
    unawaited(f1.then((_) => done = true));
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse, reason: '覆盖未生效前租约不得返回');

    backend.setGate!.complete();
    final a = await f1;
    final b = await f2;
    expect(_count(backend, 'set'), 1);
    await Future.wait([a.release(), b.release()]);
    expect(_count(backend, 'clear'), 1);
  });

  test('setDirect 超时：failed 且不阻塞；最后释放时仍 clear 防残留', () async {
    final backend = _FakeBackend()..setGate = Completer<void>();
    final route = WebViewDirectRoute(
      backend: backend,
      backendTimeout: const Duration(milliseconds: 20),
    );

    final lease = await route.acquire();
    expect(lease.status, WebViewDirectRouteStatus.failed);
    await lease.release();
    expect(_count(backend, 'clear'), 1);
  });

  group('acquireIfDartDirect', () {
    test('ignoreSystemProxy=true：Dart 强制直连 -> 取得租约', () async {
      NetworkSettings.instance.debugReset(ignoreSystemProxyValue: true);
      final backend = _FakeBackend();
      final route = WebViewDirectRoute(backend: backend);
      final lease = await route.acquireIfDartDirect();
      expect(lease, isNotNull);
      expect(_count(backend, 'set'), 1);
    });

    test('ignoreSystemProxy=false 且目标命中环境代理：不覆盖', () async {
      NetworkSettings.instance.debugReset(ignoreSystemProxyValue: false);
      debugSystemProxyLookup = (_) => 'PROXY 127.0.0.1:8888';
      final backend = _FakeBackend();
      final route = WebViewDirectRoute(backend: backend);
      expect(await route.acquireIfDartDirect(), isNull);
      expect(backend.calls, isEmpty);
    });

    test('ignoreSystemProxy=false 但无环境代理：Dart 实为直连 -> 覆盖', () async {
      NetworkSettings.instance.debugReset(ignoreSystemProxyValue: false);
      debugSystemProxyLookup = (_) => 'DIRECT';
      final backend = _FakeBackend();
      final route = WebViewDirectRoute(backend: backend);
      expect(await route.acquireIfDartDirect(), isNotNull);
    });

    test('判定函数抛异常：当作 Dart 非直连，不覆盖', () async {
      final backend = _FakeBackend();
      final route = WebViewDirectRoute(
        backend: backend,
        isDartRouteDirect: () async => throw StateError('x'),
      );
      expect(await route.acquireIfDartDirect(), isNull);
      expect(backend.calls, isEmpty);
    });
  });

  group('startGlobal', () {
    test('设置开启时常驻租约，关闭释放，重新开启再设置', () async {
      final backend = _FakeBackend();
      final route = WebViewDirectRoute(backend: backend);
      final setting = ValueNotifier<bool>(true);

      route.startGlobal(ignoreSystemProxy: setting);
      await route.debugGlobalSettled();
      expect(route.debugApplied, isTrue);
      expect(route.debugLeaseCount, 1);

      setting.value = false;
      await route.debugGlobalSettled();
      expect(route.debugApplied, isFalse);
      expect(route.debugLeaseCount, 0);
      expect(_count(backend, 'clear'), 1);

      setting.value = true;
      await route.debugGlobalSettled();
      expect(route.debugApplied, isTrue);
      expect(_count(backend, 'set'), 2);
    });

    test('页面租约与全局租约叠加：页面释放不清除全局直连', () async {
      final backend = _FakeBackend();
      final route = WebViewDirectRoute(backend: backend);
      route.startGlobal(ignoreSystemProxy: ValueNotifier<bool>(true));
      await route.debugGlobalSettled();

      final page = await route.acquire();
      await page.release();
      expect(route.debugApplied, isTrue);
      expect(_count(backend, 'clear'), 0);
    });

    test('设置关闭时不设置覆盖；重复 startGlobal 无副作用', () async {
      final backend = _FakeBackend();
      final route = WebViewDirectRoute(backend: backend);
      final setting = ValueNotifier<bool>(false);
      route.startGlobal(ignoreSystemProxy: setting);
      route.startGlobal(ignoreSystemProxy: setting);
      await route.debugGlobalSettled();
      expect(backend.calls, isEmpty);
      expect(route.debugLeaseCount, 0);
    });
  });
}
