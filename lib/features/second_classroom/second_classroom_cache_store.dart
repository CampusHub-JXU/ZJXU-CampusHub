import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/cache/json_cache_store.dart';
import '../../core/logging/app_logger.dart';
import 'second_classroom_model.dart';

/// 落在 [JsonCacheStore] 的桶名；设置页「清除离线缓存」经 `clearAll` 一并清掉。
const _cacheBucket = 'second_classroom';
const _catalogRecordKey = 'catalog';
const _activitiesRecordKey = 'activities';
const _maxActivityCacheBuckets = 12;

/// 迁移前存放在 SharedPreferences 的旧键；首次使用时一次性清除，不迁移内容。
const _legacyCatalogPrefsKey = 'second_classroom_catalog_cache_v1';
const _legacyActivityPrefsKey = 'second_classroom_activity_cache_v1';

class SecondClassroomActivityCacheSnapshot {
  const SecondClassroomActivityCacheSnapshot({
    required this.activities,
    required this.updatedAt,
  });

  final List<SecondClassroomActivity> activities;
  final DateTime updatedAt;
}

class SecondClassroomCacheStore {
  SecondClassroomCacheStore._();

  static final SecondClassroomCacheStore instance =
      SecondClassroomCacheStore._();

  final JsonCacheStore _store = JsonCacheStore.instance;
  Future<void>? _legacyPurge;

  /// 一次性清除迁移前遗留在 SharedPreferences 的旧缓存（失败不阻断缓存读写）。
  Future<void> _purgeLegacyPrefs() => _legacyPurge ??= () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyCatalogPrefsKey);
      await prefs.remove(_legacyActivityPrefsKey);
    } catch (_) {}
  }();

  Future<SecondClassroomCatalog?> loadCatalog() async {
    await _purgeLegacyPrefs();
    final record = await _store.read(_cacheBucket, _catalogRecordKey);
    final decoded = record?.payload;
    if (decoded is! Map) return null;

    try {
      return SecondClassroomCatalog.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '第二课堂目录缓存解析失败，已清空',
        error: error,
        stackTrace: stackTrace,
      );
      await _store.remove(_cacheBucket, _catalogRecordKey);
      return null;
    }
  }

  Future<void> saveCatalog(SecondClassroomCatalog catalog) async {
    await _purgeLegacyPrefs();
    await _store.write(_cacheBucket, _catalogRecordKey, catalog.toJson());
  }

  Future<SecondClassroomActivityCacheSnapshot?> loadActivities(
    SecondClassroomActivityQuery query,
  ) async {
    final cache = await _loadActivityCache();
    final bucket = cache[_queryCacheKey(query)];
    if (bucket is! Map) return null;

    final updatedAt = DateTime.tryParse(bucket['updatedAt']?.toString() ?? '');
    final rawItems = bucket['items'];
    if (updatedAt == null || rawItems is! List) return null;

    final activities = rawItems
        .whereType<Map>()
        .map(
          (json) => SecondClassroomActivity.fromStoredJson(
            Map<String, dynamic>.from(json),
          ),
        )
        .where((activity) => activity.id > 0)
        .toList(growable: false);
    return SecondClassroomActivityCacheSnapshot(
      activities: activities,
      updatedAt: updatedAt,
    );
  }

  /// 读取本地所有查询桶中缓存的二课活动并按 id 去重（零网络，首页「今日」聚合用）。
  Future<List<SecondClassroomActivity>> loadAllCachedActivities() async {
    final cache = await _loadActivityCache();
    if (cache.isEmpty) return const [];

    final byId = <int, SecondClassroomActivity>{};
    for (final bucket in cache.values) {
      if (bucket is! Map) continue;
      final rawItems = bucket['items'];
      if (rawItems is! List) continue;
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        try {
          final activity = SecondClassroomActivity.fromStoredJson(
            Map<String, dynamic>.from(raw),
          );
          if (activity.id <= 0) continue;
          final existing = byId[activity.id];
          // 已报名状态优先保留，避免旧查询桶覆盖最新报名态。
          if (existing == null ||
              (!existing.isRegistered && activity.isRegistered)) {
            byId[activity.id] = activity;
          }
        } catch (_) {
          continue;
        }
      }
    }
    return byId.values.toList(growable: false);
  }

  Future<void> saveActivities(
    SecondClassroomActivityQuery query,
    List<SecondClassroomActivity> activities,
  ) async {
    final cache = await _loadActivityCache();
    cache[_queryCacheKey(query)] = {
      'updatedAt': DateTime.now().toIso8601String(),
      'items': activities.map((activity) => activity.toJson()).toList(),
    };

    _trimCache(cache);
    await _store.write(_cacheBucket, _activitiesRecordKey, cache);
  }

  /// 活动缓存整体是一条 record（查询 key → 桶），最多保留
  /// [_maxActivityCacheBuckets] 个查询桶，超出按 updatedAt 淘汰最旧的。
  Future<Map<String, dynamic>> _loadActivityCache() async {
    await _purgeLegacyPrefs();
    final record = await _store.read(_cacheBucket, _activitiesRecordKey);
    final decoded = record?.payload;
    if (decoded is! Map) return <String, dynamic>{};
    return Map<String, dynamic>.from(decoded);
  }

  void _trimCache(Map<String, dynamic> cache) {
    if (cache.length <= _maxActivityCacheBuckets) return;
    final entries = cache.entries.toList()
      ..sort((left, right) {
        final leftTime = _bucketUpdatedAt(left.value);
        final rightTime = _bucketUpdatedAt(right.value);
        return rightTime.compareTo(leftTime);
      });
    cache
      ..clear()
      ..addEntries(entries.take(_maxActivityCacheBuckets));
  }

  DateTime _bucketUpdatedAt(Object? value) {
    if (value is! Map) return DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.tryParse(value['updatedAt']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _queryCacheKey(SecondClassroomActivityQuery query) {
    return jsonEncode({
      'categoryId': query.categoryId,
      'status': query.status.value,
      'departmentId': query.departmentId,
      'sort': query.sort.value,
      'organizationType': query.organizationType.value,
      'keyword': query.keyword.trim(),
    });
  }

  @visibleForTesting
  Future<void> debugClear() async {
    await _store.clearBucket(_cacheBucket);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyCatalogPrefsKey);
    await prefs.remove(_legacyActivityPrefsKey);
    _legacyPurge = null;
  }
}
