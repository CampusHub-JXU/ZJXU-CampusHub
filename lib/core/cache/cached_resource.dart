import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cache_policy.dart';
import 'json_cache_store.dart';

/// 一次读取的结果：值 + 它的来源与新鲜度。
///
/// UI 拿 [isStale] 决定要不要显示「正在更新」之类的轻量提示——不要据此
/// 弹错误，过期数据只是旧，不是错。
class CachedValue<T> {
  const CachedValue({
    required this.value,
    required this.updatedAt,
    required this.fromCache,
    required this.isStale,
    this.error,
  });

  final T? value;
  final DateTime? updatedAt;

  /// 本次结果来自内存 / 磁盘，未触网。
  final bool fromCache;

  /// 值已超过 [CachePolicy.ttl]，后台正在静默刷新。
  final bool isStale;

  /// 刷新失败时的原始错误；值仍可能是旧缓存。
  final Object? error;

  bool get hasValue => value != null;

  static CachedValue<T> empty<T>() => CachedValue<T>(
    value: null,
    updatedAt: null,
    fromCache: false,
    isStale: false,
  );
}

typedef CacheDecoder<T> = T? Function(Object? payload);
typedef CacheEncoder<T> = Object? Function(T value);
typedef CacheFetcher<T> = Future<T> Function();

/// 读穿式（read-through）缓存编排：内存 → 磁盘 → 网络。
///
/// 三类缓存场景在这里统一：
/// - **新鲜命中**：直接返回，零请求、零 IO。
/// - **过期但在宽限窗内**：先返回旧值顶上，后台静默重拉，完成后通过
///   [onRefreshed] 通知调用方（stale-while-revalidate）。
/// - **无缓存 / 已失效**：等网络结果；失败时若磁盘里还有旧值，返回旧值
///   并带上 [error]，由调用方决定是静默降级还是提示。
///
/// 同一实例上的并发 [get] 会合并成一次网络请求（single-flight），避免
/// 页面多个入口同时冷启动打出一串重复 RPC——寝室目录走的是串行网关队列，
/// 重复请求会实打实地排队。
class CachedResource<T> {
  CachedResource({
    required this.bucket,
    required this.key,
    required this.policy,
    required this.decode,
    required this.encode,
    required this.fetch,
    this.onRefreshed,
    JsonCacheStore? store,
  }) : _store = store ?? JsonCacheStore.instance;

  final String bucket;
  final String key;
  final CachePolicy policy;
  final CacheDecoder<T> decode;
  final CacheEncoder<T> encode;
  final CacheFetcher<T> fetch;

  /// 后台静默刷新拿到新值后的回调（SWR 路径）。
  final void Function(T value)? onRefreshed;

  final JsonCacheStore _store;

  T? _memory;
  DateTime? _memoryUpdatedAt;
  bool _memoryValid = false;
  Future<T>? _fetchFuture;

  /// 内存里的当前值（未命中缓存时为 null）。
  T? get currentValue => _memoryValid ? _memory : null;

  DateTime? get currentUpdatedAt => _memoryValid ? _memoryUpdatedAt : null;

  Future<CachedValue<T>> get({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final hit = await _readCache();
      if (hit != null) return hit;
    }
    return _loadFromNetwork();
  }

  /// 主动刷新并等待结果（下拉刷新、用户点了重试）。
  Future<T?> refresh() async {
    try {
      return await _fetchShared();
    } catch (_) {
      return currentValue;
    }
  }

  /// 作废缓存：内存与磁盘一起清。
  Future<void> invalidate() async {
    _memory = null;
    _memoryUpdatedAt = null;
    _memoryValid = false;
    await _store.remove(bucket, key);
  }

  @visibleForTesting
  void debugReset() {
    _memory = null;
    _memoryUpdatedAt = null;
    _memoryValid = false;
    _fetchFuture = null;
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  /// 依次尝试内存与磁盘；命中即返回（过期项附带后台刷新），未命中返回
  /// null 交给网络分支。
  Future<CachedValue<T>?> _readCache() async {
    final memoryAge = _memoryAge();
    if (memoryAge != null) {
      final freshness = policy.freshnessOf(memoryAge);
      if (freshness == CacheFreshness.fresh) {
        return _fromMemory(isStale: false);
      }
      if (freshness == CacheFreshness.stale) {
        _revalidate();
        return _fromMemory(isStale: true);
      }
      _memoryValid = false;
    }

    final record = await _store.read(bucket, key);
    if (record == null) return null;
    final value = decode(record.payload);
    if (value == null) {
      // 结构对不上（model 改过但版本号没升）：丢掉，别让坏数据长期留存。
      await _store.remove(bucket, key);
      return null;
    }

    final age = DateTime.now().difference(record.updatedAt);
    final freshness = policy.freshnessOf(age);
    if (freshness == CacheFreshness.expired) return null;

    _memory = value;
    _memoryUpdatedAt = record.updatedAt;
    _memoryValid = true;

    if (freshness == CacheFreshness.stale) _revalidate();
    return _fromMemory(isStale: freshness == CacheFreshness.stale);
  }

  Duration? _memoryAge() {
    if (!_memoryValid || _memory == null || _memoryUpdatedAt == null) {
      return null;
    }
    return DateTime.now().difference(_memoryUpdatedAt!);
  }

  CachedValue<T> _fromMemory({required bool isStale}) {
    return CachedValue<T>(
      value: _memory,
      updatedAt: _memoryUpdatedAt,
      fromCache: true,
      isStale: isStale,
    );
  }

  Future<CachedValue<T>> _loadFromNetwork() async {
    final fallback = _memoryValid ? _memory : null;
    final fallbackAt = _memoryValid ? _memoryUpdatedAt : null;
    try {
      final value = await _fetchShared();
      return CachedValue<T>(
        value: value,
        updatedAt: _memoryUpdatedAt,
        fromCache: false,
        isStale: false,
      );
    } catch (error) {
      if (fallback != null) {
        return CachedValue<T>(
          value: fallback,
          updatedAt: fallbackAt,
          fromCache: true,
          isStale: true,
          error: error,
        );
      }
      return CachedValue<T>(
        value: null,
        updatedAt: null,
        fromCache: false,
        isStale: false,
        error: error,
      );
    }
  }

  /// 后台静默刷新：不 await，完成后回调 [onRefreshed]。
  void _revalidate() {
    if (_fetchFuture != null) return;
    unawaited(
      _fetchShared().then(
        (value) {
          onRefreshed?.call(value);
        },
        onError: (Object _) {
          // 静默刷新失败不打扰用户：旧值还在屏幕上。
        },
      ),
    );
  }

  /// 网络请求合并：同一实例上的并发调用共享一个 Future。
  Future<T> _fetchShared() {
    final existing = _fetchFuture;
    if (existing != null) return existing;
    final future = _fetchAndStore();
    _fetchFuture = future;
    unawaited(
      future.then<void>(
        (_) => _clearFetchFuture(future),
        onError: (Object _, StackTrace _) => _clearFetchFuture(future),
      ),
    );
    return future;
  }

  void _clearFetchFuture(Future<T> future) {
    if (identical(_fetchFuture, future)) _fetchFuture = null;
  }

  Future<T> _fetchAndStore() async {
    final value = await fetch();
    _memory = value;
    _memoryUpdatedAt = DateTime.now();
    _memoryValid = true;
    if (!policy.isVolatile) {
      await _store.write(
        bucket,
        key,
        encode(value),
        updatedAt: _memoryUpdatedAt,
      );
    }
    return value;
  }
}
