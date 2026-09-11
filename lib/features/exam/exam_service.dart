import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/academic_auth_guard.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/network/dio_client.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/schedule_term_context.dart';
import '../../core/system_surface/campus_data_change_bus.dart';
import 'exam_model.dart';

class ExamService {
  ExamService._();
  static final ExamService instance = ExamService._();

  static const _cacheKey = 'exam_cached_data';
  List<ExamEntry>? _cachedExams;

  List<ExamEntry>? get cachedExams => _cachedExams;

  ExamEntry? get nextExam {
    if (_cachedExams == null) return null;
    for (final exam in _cachedExams!) {
      if (exam.hasDate && !exam.isPast) return exam;
    }
    return null;
  }

  @visibleForTesting
  void debugReset() {
    _cachedExams = null;
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
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistCache(List<ExamEntry> exams) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode(exams.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
    CampusDataChangeBus.instance.notifyChanged();
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
    final dio = ZhengfangAuth.instance.academicDio;

    final resolvedId = studentId?.trim().isNotEmpty == true
        ? studentId!.trim()
        : ZhengfangAuth.instance.currentStudentId ?? '';
    if (resolvedId.isEmpty) {
      throw const ExamRequestException('未获取到学号，请先登录教务系统');
    }

    // 与课表一致：优先以教务系统解析的当前学期为准，失败时按日期推算。
    final termContext =
        await CurrentTermResolver.instance.resolve(studentId: resolvedId) ??
        ScheduleTermContext.current();
    final academicYear = termContext.academicYear;
    final term = termContext.term;
    final ts = DateTime.now().millisecondsSinceEpoch;

    try {
      final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        authExpiredException: const ExamAuthExpiredException(),
        request: () => dio.post<Map<String, dynamic>>(
          ZhengfangAuth.instance.buildPortalUrl(
            '/kwgl/kscx_cxXsksxxIndex.html',
          ),
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
            headers: {
              'Referer': ZhengfangAuth.instance.academicServiceUrl,
              'X-Requested-With': 'XMLHttpRequest',
            },
          ),
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
    } on ExamAuthExpiredException {
      rethrow;
    } on AcademicAuthExpiredException {
      throw const ExamAuthExpiredException();
    } on DioException catch (e) {
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
