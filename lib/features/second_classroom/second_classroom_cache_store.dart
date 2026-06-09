import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logging/app_logger.dart';
import 'second_classroom_model.dart';

const _catalogCacheKey = 'second_classroom_catalog_cache_v1';
const _activityCacheKey = 'second_classroom_activity_cache_v1';
const _maxActivityCacheBuckets = 12;

class SecondClassroomActivityCacheSnapshot {
  const SecondClassroomActivityCacheSnapshot({
    required this.activities,
    required this.updatedAt,
  });

  final List<SecondClassroomActivity> activities;
  final DateTime updatedAt;

  bool get isEmpty => activities.isEmpty;
}

class SecondClassroomCacheStore {
  SecondClassroomCacheStore._();

  static final SecondClassroomCacheStore instance =
      SecondClassroomCacheStore._();

  Future<SecondClassroomCatalog?> loadCatalog() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_catalogCacheKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
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
      await prefs.remove(_catalogCacheKey);
      return null;
    }
  }

  Future<void> saveCatalog(SecondClassroomCatalog catalog) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_catalogCacheKey, jsonEncode(catalog.toJson()));
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

  Future<void> saveActivities(
    SecondClassroomActivityQuery query,
    List<SecondClassroomActivity> activities,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final cache = await _loadActivityCache();
    cache[_queryCacheKey(query)] = {
      'updatedAt': DateTime.now().toIso8601String(),
      'items': activities.map((activity) => activity.toJson()).toList(),
    };

    _trimCache(cache);
    await prefs.setString(_activityCacheKey, jsonEncode(cache));
  }

  Future<Map<String, dynamic>> _loadActivityCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_activityCacheKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, dynamic>{};
      return Map<String, dynamic>.from(decoded);
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '第二课堂活动缓存解析失败，已清空',
        error: error,
        stackTrace: stackTrace,
      );
      await prefs.remove(_activityCacheKey);
      return <String, dynamic>{};
    }
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_catalogCacheKey);
    await prefs.remove(_activityCacheKey);
  }
}
