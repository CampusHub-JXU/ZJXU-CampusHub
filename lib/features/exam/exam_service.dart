import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/network/dio_client.dart';
import 'exam_model.dart';

class ExamService {
  ExamService._();
  static final ExamService instance = ExamService._();

  static const _cacheKey = 'exam_cached_data';
  static const _cacheTimeKey = 'exam_cached_at';

  List<ExamEntry>? _cachedExams;

  List<ExamEntry>? get cachedExams => _cachedExams;
  DateTime? get lastSavedAt => _lastSavedAt;

  ExamEntry? get nextExam {
    if (_cachedExams == null) return null;
    for (final exam in _cachedExams!) {
      if (exam.hasDate && !exam.isPast) return exam;
    }
    return null;
  }

  List<ExamEntry> get upcomingExams {
    if (_cachedExams == null) return [];
    return _cachedExams!.where((e) => e.hasDate && !e.isPast).toList();
  }

  @visibleForTesting
  void debugReset() {
    _cachedExams = null;
    _lastSavedAt = null;
  }

  /// Restore exam cache from disk. Returns true if data was restored.
  Future<bool> restoreCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return false;
      final list =
          (jsonDecode(raw) as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map(ExamEntry.fromJson)
              .toList()
            ..sort((a, b) {
              if (!a.hasDate && !b.hasDate) return 0;
              if (!a.hasDate) return 1;
              if (!b.hasDate) return -1;
              return a.examDate!.compareTo(b.examDate!);
            });
      _cachedExams = list;
      final savedAt = prefs.getInt(_cacheTimeKey);
      if (savedAt != null) {
        _lastSavedAt = DateTime.fromMillisecondsSinceEpoch(savedAt);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Exam cache is kept until a successful refresh replaces it.
  bool get hasCache => _cachedExams != null;

  DateTime? _lastSavedAt;

  Future<void> _persistCache(List<ExamEntry> exams) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode(exams.map((e) => e.toJson()).toList()),
      );
      _lastSavedAt = DateTime.now();
      await prefs.setInt(_cacheTimeKey, _lastSavedAt!.millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Fetch exams from network, with cache-first strategy.
  /// If [forceRefresh] is false and cache exists, returns cached data.
  Future<List<ExamEntry>> fetchExams({
    String? studentId,
    bool forceRefresh = false,
  }) async {
    // Return in-memory cache until the user or caller explicitly refreshes.
    if (!forceRefresh && _cachedExams != null) {
      return _cachedExams!;
    }

    await DioClient.instance.ensureInitialized();
    final dio = DioClient.instance.dio;

    final resolvedId = studentId?.trim().isNotEmpty == true
        ? studentId!.trim()
        : ZhengfangAuth.instance.currentStudentId ?? '';
    if (resolvedId.isEmpty) {
      throw const ExamRequestException('未获取到学号，请先登录教务系统');
    }

    final now = DateTime.now();
    final academicYear = now.month < 8 ? now.year - 1 : now.year;
    final term = now.month >= 2 && now.month < 8 ? 12 : 3;
    final ts = now.millisecondsSinceEpoch;

    try {
      final resp = await dio.post<Map<String, dynamic>>(
        '/kwgl/kscx_cxXsksxxIndex.html',
        queryParameters: {
          'doType': 'query',
          'gnmkdm': 'N358105',
          'su': resolvedId,
        },
        data:
            'xnm=$academicYear&xqm=$term&ksmcdmb_id=&kch=&kc=&ksrq='
            '&kkbm_id=&ksmc=&_search=false&nd=$ts'
            '&queryModel.showCount=100&queryModel.currentPage=1'
            '&queryModel.sortName=&queryModel.sortOrder=asc&time=0',
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          headers: {'x-requested-with': 'XMLHttpRequest'},
        ),
      );

      final items = resp.data?['items'] as List<dynamic>? ?? [];
      final exams =
          items.cast<Map<String, dynamic>>().map(ExamEntry.fromJson).toList()
            ..sort((a, b) {
              if (!a.hasDate && !b.hasDate) return 0;
              if (!a.hasDate) return 1;
              if (!b.hasDate) return -1;
              return a.examDate!.compareTo(b.examDate!);
            });

      _cachedExams = exams;
      await _persistCache(exams);
      return exams;
    } on DioException catch (e) {
      if (e.response?.statusCode == 302 || e.response?.statusCode == 403) {
        throw const ExamAuthExpiredException();
      }
      throw ExamRequestException('获取考试信息失败：${e.message}');
    }
  }
}

class ExamRequestException implements Exception {
  const ExamRequestException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ExamAuthExpiredException extends ExamRequestException {
  const ExamAuthExpiredException() : super('登录状态已过期，请重新登录');
}
