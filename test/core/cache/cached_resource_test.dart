import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/cache/cache_policy.dart';
import 'package:jxu_campus_hub/core/cache/cached_resource.dart';
import 'package:jxu_campus_hub/core/cache/json_cache_store.dart';

import '../../helpers/test_setup.dart';

/// 手写 fetch 替身：既能计数，也能用 [gate] 卡住完成时机。
class _FakeFetcher {
  _FakeFetcher(this.result);

  List<String> result;
  Object? error;
  Completer<List<String>>? gate;
  int calls = 0;

  Future<List<String>> call() {
    calls++;
    final pending = gate;
    if (pending != null) {
      gate = null;
      return pending.future;
    }
    final failure = error;
    if (failure != null) return Future<List<String>>.error(failure);
    return Future<List<String>>.value(result);
  }
}

/// 轮询等待条件成立，避免测试依赖固定的 sleep 时长。
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = '条件未在超时前满足',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  const bucket = 'test_bucket';
  const key = 'test_key';

  Directory? tempDir;

  setUp(() async {
    await resetTestEnvironment();
    tempDir = await Directory.systemTemp.createTemp('cached_resource_test');
    JsonCacheStore.instance.debugDirectoryProvider = () async => tempDir!;
  });

  tearDown(() async {
    await JsonCacheStore.instance.debugClear();
    JsonCacheStore.instance.debugReset();
    tempDir?.deleteSync(recursive: true);
    tempDir = null;
  });

  CachedResource<List<String>> buildResource(
    _FakeFetcher fetcher, {
    CachePolicy policy = CachePolicy.daily,
    void Function(List<String> value)? onRefreshed,
  }) {
    return CachedResource<List<String>>(
      bucket: bucket,
      key: key,
      policy: policy,
      decode: (payload) => payload is List
          ? payload.map((item) => item.toString()).toList()
          : null,
      encode: (value) => value,
      fetch: fetcher.call,
      onRefreshed: onRefreshed,
      store: JsonCacheStore.instance,
    );
  }

  /// 直接往磁盘塞一条指定年龄的记录。
  Future<void> seedDisk(List<String> value, Duration age) {
    return JsonCacheStore.instance.write(
      bucket,
      key,
      value,
      updatedAt: DateTime.now().subtract(age),
    );
  }

  Future<CacheRecord?> diskRecord() =>
      JsonCacheStore.instance.read(bucket, key);

  group('缓存未命中 / 失效', () {
    test('首次读取回源，并同时写入内存与磁盘', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);

      final result = await resource.get();

      expect(result.value, equals(['v1']));
      expect(result.fromCache, isFalse);
      expect(result.isStale, isFalse);
      expect(result.hasValue, isTrue);
      expect(result.error, isNull);
      expect(fetcher.calls, 1);
      expect(resource.currentValue, equals(['v1']));
      expect(resource.currentUpdatedAt, isNotNull);
      expect((await diskRecord())!.payload, equals(['v1']));
    });

    test('缓存超过 ttl + staleGrace 时回源', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      // daily：ttl 8h + grace 3d，这里放到 4 天前。
      await seedDisk(['old'], const Duration(days: 4));

      final result = await resource.get();

      expect(result.value, equals(['v1']));
      expect(result.fromCache, isFalse);
      expect(result.isStale, isFalse);
      expect(fetcher.calls, 1);
    });

    test('无缓存且回源失败：返回空值并带 error', () async {
      final fetcher = _FakeFetcher(['v1'])..error = StateError('boom');
      final resource = buildResource(fetcher);

      final result = await resource.get();

      expect(result.hasValue, isFalse);
      expect(result.value, isNull);
      expect(result.updatedAt, isNull);
      expect(result.fromCache, isFalse);
      expect(result.isStale, isFalse);
      expect(result.error, isA<StateError>());
      expect(fetcher.calls, 1);
      expect(await diskRecord(), isNull);
    });
  });

  group('新鲜命中', () {
    test('内存命中且新鲜时不再触网', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();

      final second = await resource.get();

      expect(second.value, equals(['v1']));
      expect(second.fromCache, isTrue);
      expect(second.isStale, isFalse);
      expect(fetcher.calls, 1);
    });

    test('内存清空后命中磁盘新鲜条目，同样不触网', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();
      resource.debugReset();

      final again = await resource.get();

      expect(again.value, equals(['v1']));
      expect(again.fromCache, isTrue);
      expect(again.isStale, isFalse);
      expect(fetcher.calls, 1);
    });
  });

  group('stale-while-revalidate', () {
    test('宽限窗内先返回旧值并标记 isStale，刷新成功后回调 onRefreshed', () async {
      final fetcher = _FakeFetcher(['new']);
      final gate = Completer<List<String>>();
      fetcher.gate = gate;
      final refreshed = <List<String>>[];
      final resource = buildResource(fetcher, onRefreshed: refreshed.add);
      await seedDisk(['old'], const Duration(hours: 9));

      final result = await resource.get();

      expect(result.value, equals(['old']));
      expect(result.fromCache, isTrue);
      expect(result.isStale, isTrue);
      expect(fetcher.calls, 1);
      expect(refreshed, isEmpty);

      gate.complete(['new']);
      await _waitFor(() => refreshed.isNotEmpty);

      expect(refreshed, hasLength(1));
      expect(refreshed.single, equals(['new']));
      expect(resource.currentValue, equals(['new']));
      expect((await diskRecord())!.payload, equals(['new']));
    });

    test('刷新仍在进行时重复 get 不会重复发起请求', () async {
      final fetcher = _FakeFetcher(['new']);
      final gate = Completer<List<String>>();
      fetcher.gate = gate;
      final refreshed = <List<String>>[];
      final resource = buildResource(fetcher, onRefreshed: refreshed.add);
      await seedDisk(['old'], const Duration(hours: 9));

      final first = await resource.get();
      final second = await resource.get();

      expect(first.isStale, isTrue);
      expect(second.isStale, isTrue);
      expect(second.value, equals(['old']));
      expect(fetcher.calls, 1);

      gate.complete(['new']);
      await _waitFor(() => refreshed.isNotEmpty);

      expect(refreshed, hasLength(1));
      expect(fetcher.calls, 1);
    });

    test('后台刷新失败时不回调，旧值继续留在内存', () async {
      final fetcher = _FakeFetcher(['v1'])..error = StateError('boom');
      final refreshed = <List<String>>[];
      final resource = buildResource(fetcher, onRefreshed: refreshed.add);
      await seedDisk(['old'], const Duration(hours: 9));

      final result = await resource.get();
      await _waitFor(() => fetcher.calls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(result.value, equals(['old']));
      expect(result.isStale, isTrue);
      expect(refreshed, isEmpty);
      expect(resource.currentValue, equals(['old']));
    });
  });

  group('single-flight', () {
    test('并发 get 只触发一次 fetch，且共享同一结果', () async {
      final fetcher = _FakeFetcher(['v1']);
      final gate = Completer<List<String>>();
      fetcher.gate = gate;
      final resource = buildResource(fetcher);

      final first = resource.get();
      final second = resource.get();
      await _waitFor(() => fetcher.calls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fetcher.calls, 1);

      gate.complete(['shared']);
      final firstResult = await first;
      final secondResult = await second;

      expect(fetcher.calls, 1);
      expect(firstResult.value, equals(['shared']));
      expect(secondResult.value, equals(['shared']));
      expect(secondResult.fromCache, isFalse);
    });

    test('上一轮请求结束后可以再次发起', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);

      await Future.wait(<Future<CachedValue<List<String>>>>[
        resource.get(),
        resource.get(),
      ]);
      expect(fetcher.calls, 1);

      fetcher.result = ['v2'];
      final again = await resource.get();
      expect(fetcher.calls, 1, reason: '内存仍然新鲜，无需回源');

      final forced = await resource.get(forceRefresh: true);
      expect(forced.value, equals(['v2']));
      expect(fetcher.calls, 2);
      expect(again.value, equals(['v1']));
    });

    test('失败的请求结束后可以重新发起', () async {
      final fetcher = _FakeFetcher(['v1'])..error = StateError('boom');
      final resource = buildResource(fetcher);

      final failed = await Future.wait(<Future<CachedValue<List<String>>>>[
        resource.get(),
        resource.get(),
      ]);
      expect(fetcher.calls, 1);
      expect(failed.every((result) => result.error is StateError), isTrue);

      fetcher.error = null;
      fetcher.result = ['recovered'];
      final recovered = await resource.get();

      expect(fetcher.calls, 2);
      expect(recovered.value, equals(['recovered']));
    });
  });

  group('forceRefresh', () {
    test('跳过缓存直接回源并更新内存', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();
      fetcher.result = ['v2'];

      final result = await resource.get(forceRefresh: true);

      expect(fetcher.calls, 2);
      expect(result.value, equals(['v2']));
      expect(result.fromCache, isFalse);
      expect(result.isStale, isFalse);
      expect(resource.currentValue, equals(['v2']));
      expect((await diskRecord())!.payload, equals(['v2']));
    });

    test('回源失败时返回内存中已有的旧值并带 error', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();
      fetcher.error = StateError('boom');

      final result = await resource.get(forceRefresh: true);

      expect(result.value, equals(['v1']));
      expect(result.fromCache, isTrue);
      expect(result.isStale, isTrue);
      expect(result.error, isA<StateError>());
      expect(fetcher.calls, 2);
    });
  });

  group('refresh', () {
    test('主动刷新强制触网并等待结果', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();
      fetcher.result = ['v2'];

      final value = await resource.refresh();

      expect(value, equals(['v2']));
      expect(fetcher.calls, 2);
      expect(resource.currentValue, equals(['v2']));
    });

    test('刷新失败时返回当前内存值', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();
      fetcher.error = StateError('boom');

      final value = await resource.refresh();

      expect(value, equals(['v1']));
      expect(fetcher.calls, 2);
    });

    test('刷新失败且无缓存值时返回 null', () async {
      final fetcher = _FakeFetcher(['v1'])..error = StateError('boom');
      final resource = buildResource(fetcher);

      expect(await resource.refresh(), isNull);
      expect(fetcher.calls, 1);
    });
  });

  group('invalidate', () {
    test('同时清掉内存与磁盘，下一次读取重新回源', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();
      expect(resource.currentValue, equals(['v1']));
      expect(await diskRecord(), isNotNull);

      await resource.invalidate();

      expect(resource.currentValue, isNull);
      expect(resource.currentUpdatedAt, isNull);
      expect(await diskRecord(), isNull);

      fetcher.result = ['v2'];
      final again = await resource.get();
      expect(again.fromCache, isFalse);
      expect(again.value, equals(['v2']));
      expect(fetcher.calls, 2);
    });

    test('invalidate 不影响同 bucket 下的其它 key', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher);
      await resource.get();
      await JsonCacheStore.instance.write(bucket, 'other_key', ['keep']);

      await resource.invalidate();

      expect(
        (await JsonCacheStore.instance.read(bucket, 'other_key'))!.payload,
        equals(['keep']),
      );
    });
  });

  group('volatile 策略', () {
    test('回源成功但不落盘', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher, policy: CachePolicy.volatile);

      final result = await resource.get();

      expect(result.value, equals(['v1']));
      expect(result.fromCache, isFalse);
      expect(resource.currentValue, equals(['v1']));
      expect(await diskRecord(), isNull);
    });

    test('ttl 为 0，每次读取都重新回源', () async {
      final fetcher = _FakeFetcher(['v1']);
      final resource = buildResource(fetcher, policy: CachePolicy.volatile);

      await resource.get();
      // 保证 age > 0，volatile 下任何正年龄都已失效。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await resource.get();

      expect(fetcher.calls, 2);
      expect(await diskRecord(), isNull);
    });
  });

  group('磁盘记录解码', () {
    test('无法解码的记录被丢弃并回源', () async {
      final fetcher = _FakeFetcher(['v1'])..error = StateError('boom');
      final resource = buildResource(fetcher);
      await seedDisk(['old'], const Duration(minutes: 1));
      await JsonCacheStore.instance.write(bucket, key, <String, dynamic>{
        'unexpected': 'shape',
      }, updatedAt: DateTime.now());

      final result = await resource.get();

      expect(fetcher.calls, 1);
      expect(result.value, isNull);
      expect(result.error, isA<StateError>());
      // 坏记录已被移除，不会继续毒化后续解析。
      expect(await diskRecord(), isNull);
    });
  });

  group('CachedValue', () {
    test('empty 构造出无任何数据的结果', () {
      final value = CachedValue.empty<String>();

      expect(value.hasValue, isFalse);
      expect(value.value, isNull);
      expect(value.updatedAt, isNull);
      expect(value.fromCache, isFalse);
      expect(value.isStale, isFalse);
      expect(value.error, isNull);
    });

    test('hasValue 只取决于 value 是否为 null', () {
      expect(
        CachedValue<String>(
          value: 'x',
          updatedAt: null,
          fromCache: true,
          isStale: false,
        ).hasValue,
        isTrue,
      );
      expect(
        CachedValue<String>(
          value: null,
          updatedAt: null,
          fromCache: false,
          isStale: false,
        ).hasValue,
        isFalse,
      );
    });
  });
}
