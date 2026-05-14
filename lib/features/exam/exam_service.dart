import 'package:dio/dio.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/network/dio_client.dart';
import 'exam_model.dart';

class ExamService {
  ExamService._();
  static final ExamService instance = ExamService._();

  List<ExamEntry>? _cachedExams;

  List<ExamEntry>? get cachedExams => _cachedExams;

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

  Future<List<ExamEntry>> fetchExams([String? studentId]) async {
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
