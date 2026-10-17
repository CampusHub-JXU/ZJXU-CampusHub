import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_logger.dart';
import '../storage/atomic_json_file.dart';

/// 单条缓存记录：写入时刻 + 已编码的载荷。
class CacheRecord {
  const CacheRecord({required this.updatedAt, required this.payload});

  final DateTime updatedAt;
  final Object? payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'updatedAt': updatedAt.toIso8601String(),
    'payload': payload,
  };

  static CacheRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final updatedAt = DateTime.tryParse(raw['updatedAt']?.toString() ?? '');
    if (updatedAt == null) return null;
    return CacheRecord(updatedAt: updatedAt, payload: raw['payload']);
  }
}

/// 基于 JSON 文件的分桶缓存存储。
///
/// 为什么不用 SharedPreferences：寝室全量目录在 200~400KB 量级，SP 是全量
/// 读写（改一个键要重写整个文件）且走主线程；分桶 JSON 文件只在读写的那
/// 一刻占用 IO，读入后常驻内存镜像，命中即无 IO。
///
/// 每个 bucket 对应一个 `<bucket>.json`，内容形如：
/// ```json
/// {"v": 1, "entries": {"<key>": {"updatedAt": "...", "payload": ...}}}
/// ```
/// `v` 为 [schemaVersion]：model 结构变更时递增，旧文件整桶作废，不必为
/// 每个 key 写迁移。
class JsonCacheStore {
  JsonCacheStore._();

  static final JsonCacheStore instance = JsonCacheStore._();

  /// 载荷结构版本。改动任何接入方的 encode/decode 之后递增。
  static const int schemaVersion = 1;

  Directory? _cacheDir;
  final Map<String, Map<String, CacheRecord>> _buckets =
      <String, Map<String, CacheRecord>>{};
  final Map<String, Future<Map<String, CacheRecord>>> _loadFutures =
      <String, Future<Map<String, CacheRecord>>>{};
  final Map<String, Future<void>> _writeTails = <String, Future<void>>{};

  /// 本 isolate 最近一次读 / 写后看到的桶文件修改时间。主引擎与 WorkManager
  /// 后台引擎各有一份内存镜像：命中镜像前比对 mtime，别的 isolate 写过就重读，
  /// 免得用陈旧整桶覆盖对方的写入。只收窄竞争，没有跨 isolate 锁。
  final Map<String, DateTime?> _bucketStamps = <String, DateTime?>{};

  /// 测试替身：注入临时目录，避免碰真实应用文档目录。
  @visibleForTesting
  Future<Directory> Function()? debugDirectoryProvider;

  Future<Directory> _resolveCacheDir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final override = debugDirectoryProvider;
    final Directory root;
    if (override != null) {
      root = await override();
    } else {
      root = await getTemporaryDirectory();
    }
    final dir = Directory('${root.path}${Platform.pathSeparator}json_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  /// 读一条记录；不存在或已损坏返回 null（损坏时整桶重建，不让坏数据
  /// 反复毒化解析逻辑）。
  Future<CacheRecord?> read(String bucket, String key) async {
    final records = await _loadBucket(bucket);
    return records[key];
  }

  Future<void> write(
    String bucket,
    String key,
    Object? payload, {
    DateTime? updatedAt,
  }) async {
    final records = await _loadBucket(bucket);
    records[key] = CacheRecord(
      updatedAt: updatedAt ?? DateTime.now(),
      payload: payload,
    );
    await _persistBucket(bucket, records);
  }

  Future<void> remove(String bucket, String key) async {
    final records = await _loadBucket(bucket);
    if (records.remove(key) == null) return;
    await _persistBucket(bucket, records);
  }

  Future<void> clearBucket(String bucket) async {
    _buckets.remove(bucket);
    _bucketStamps.remove(bucket);
    await _persistBucket(bucket, <String, CacheRecord>{});
  }

  /// 清空全部缓存桶与落盘文件（设置页「清除离线缓存」）。
  ///
  /// 只动离线缓存目录，不影响登录态、偏好设置与用户背景图。
  Future<void> clearAll() async {
    await Future.wait<void>(_writeTails.values);
    _buckets.clear();
    _bucketStamps.clear();
    _loadFutures.clear();
    final dir = _cacheDir;
    _cacheDir = null;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @visibleForTesting
  Future<void> debugClear() async {
    await Future.wait<void>(_writeTails.values);
    _buckets.clear();
    _bucketStamps.clear();
    _loadFutures.clear();
    final dir = _cacheDir;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _cacheDir = null;
  }

  @visibleForTesting
  void debugReset() {
    _buckets.clear();
    _bucketStamps.clear();
    _loadFutures.clear();
    _writeTails.clear();
    _cacheDir = null;
    debugDirectoryProvider = null;
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<Map<String, CacheRecord>> _loadBucket(String bucket) async {
    final cached = _buckets[bucket];
    if (cached != null) {
      // 本 isolate 有排队中的写入时镜像比磁盘新，直接用。
      if (_writeTails.containsKey(bucket)) return cached;
      final stamp = await _fileStamp(bucket);
      if (stamp == _bucketStamps[bucket]) return cached;
      _buckets.remove(bucket);
    }

    final loading = _loadFutures[bucket];
    if (loading != null) return loading;

    final future = _readBucket(bucket);
    _loadFutures[bucket] = future;
    try {
      return await future;
    } finally {
      if (identical(_loadFutures[bucket], future)) {
        _loadFutures.remove(bucket);
      }
    }
  }

  Future<Map<String, CacheRecord>> _readBucket(String bucket) async {
    final file = await _bucketFile(bucket);
    final records = <String, CacheRecord>{};
    _bucketStamps[bucket] = await _fileStamp(bucket);
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map && raw['v'] == schemaVersion) {
          final entries = raw['entries'];
          if (entries is Map) {
            entries.forEach((key, value) {
              final record = CacheRecord.fromJson(value);
              if (record != null) records[key.toString()] = record;
            });
          }
        } else {
          // 版本不匹配：整桶丢弃，不走迁移。
          await _safeDelete(file);
        }
      } catch (error, stackTrace) {
        AppLogger.instance.storage(
          LogLevel.warn,
          '缓存 $bucket 解析失败，已丢弃',
          error: error,
          stackTrace: stackTrace,
        );
        await _safeDelete(file);
      }
    }
    _buckets[bucket] = records;
    return records;
  }

  /// 落盘。同一 bucket 的写操作串行排队，避免并发 read-modify-write 互相
  /// 覆盖成旧内容。
  Future<void> _persistBucket(String bucket, Map<String, CacheRecord> records) {
    final previous = _writeTails[bucket] ?? Future<void>.value();
    final operation = previous.then(
      (_) => _writeBucketFile(bucket, records),
      onError: (_) => _writeBucketFile(bucket, records),
    );
    final tail = operation.catchError((Object _) {});
    _writeTails[bucket] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_writeTails[bucket], tail)) {
          _writeTails.remove(bucket);
        }
      }),
    );
    return operation;
  }

  Future<void> _writeBucketFile(
    String bucket,
    Map<String, CacheRecord> records,
  ) async {
    final file = await _bucketFile(bucket);
    final json = <String, dynamic>{
      'v': schemaVersion,
      'entries': records.map(
        (key, record) => MapEntry<String, dynamic>(key, record.toJson()),
      ),
    };
    try {
      // 临时文件 + rename：写到一半被杀不会留下截断文件（读到坏文件会整桶删除）。
      await AtomicJsonFile.write(file, json);
      _bucketStamps[bucket] = await _fileStamp(bucket);
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '缓存 $bucket 写入失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<File> _bucketFile(String bucket) async {
    final dir = await _resolveCacheDir();
    return File('${dir.path}${Platform.pathSeparator}$bucket.json');
  }

  Future<DateTime?> _fileStamp(String bucket) async {
    try {
      final stat = await (await _bucketFile(bucket)).stat();
      return stat.type == FileSystemEntityType.notFound ? null : stat.modified;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
