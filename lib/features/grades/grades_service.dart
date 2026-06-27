import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/network/dio_client.dart';
import 'grades_model.dart';

class GradesService {
  GradesService._();
  static final GradesService instance = GradesService._();

  static const _cacheKey = 'grades_cached_data';
  static const _cacheTimeKey = 'grades_cached_at';
  static const _refreshWindow = Duration(hours: 12);

  List<GradeEntry>? _cachedGrades;
  DateTime? _lastSavedAt;

  bool get isCacheFresh {
    if (_lastSavedAt == null) return false;
    return DateTime.now().difference(_lastSavedAt!) < _refreshWindow;
  }

  List<GradeEntry>? get cachedGrades => _cachedGrades;

  Future<bool> restoreCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_cacheKey);
      final ts = prefs.getInt(_cacheTimeKey);
      if (json == null || ts == null) return false;

      final list = (jsonDecode(json) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(GradeEntry.fromJson)
          .toList();

      _cachedGrades = list;
      _lastSavedAt = DateTime.fromMillisecondsSinceEpoch(ts);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistCache(List<GradeEntry> grades) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cacheKey,
      jsonEncode(grades.map((e) => e.toJson()).toList()),
    );
    await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
    _cachedGrades = grades;
    _lastSavedAt = DateTime.now();
  }

  Future<List<GradeEntry>> fetchGrades(
    String studentId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && isCacheFresh && _cachedGrades != null) {
      return _cachedGrades!;
    }

    await DioClient.instance.ensureInitialized();
    final dio = ZhengfangAuth.instance.academicDio;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final resp = await dio.post<Map<String, dynamic>>(
      ZhengfangAuth.instance.buildPortalUrl('/cjcx/cjcx_cxDgXscj.html'),
      queryParameters: {
        'doType': 'query',
        'gnmkdm': 'N305005',
        'su': studentId,
      },
      data:
          'xnm=&xqm=&_search=false&nd=$ts'
          '&queryModel.showCount=100&queryModel.currentPage=1'
          '&queryModel.sortName=&queryModel.sortOrder=asc&time=1',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: {
          'Referer': ZhengfangAuth.instance.academicServiceUrl,
          'X-Requested-With': 'XMLHttpRequest',
        },
      ),
    );

    final items = resp.data?['items'] as List<dynamic>? ?? [];
    final grades = items
        .cast<Map<String, dynamic>>()
        .map(GradeEntry.fromJson)
        .toList();

    await _persistCache(grades);
    return grades;
  }

  @visibleForTesting
  void debugReset() {
    _cachedGrades = null;
    _lastSavedAt = null;
  }
}
