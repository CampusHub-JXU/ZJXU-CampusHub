import 'package:dio/dio.dart';

import '../../core/network/dio_client.dart';
import '../../core/semester/semester_calendar.dart';
import 'schedule_model.dart';

class ScheduleRequestException implements Exception {
  const ScheduleRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ScheduleAuthExpiredException extends ScheduleRequestException {
  const ScheduleAuthExpiredException() : super('登录状态已过期，请重新登录');
}

class CourseCancellationRule {
  const CourseCancellationRule({
    required this.week,
    required this.weekday,
    required this.startLesson,
    required this.endLesson,
    this.courseName,
  });

  final int week;
  final int weekday;
  final int startLesson;
  final int endLesson;
  final String? courseName;
}

class _LessonInfo {
  const _LessonInfo({
    required this.week,
    required this.weekday,
    required this.startLesson,
    required this.endLesson,
  });

  final int week;
  final int weekday;
  final int startLesson;
  final int endLesson;
}

class ScheduleService {
  ScheduleService._();
  static final ScheduleService instance = ScheduleService._();

  final _dio = DioClient.instance.dio;

  /// 获取当前周次
  int getCurrentWeek() {
    return SemesterCalendar.instance.weekForDate(DateTime.now());
  }

  /// [term]: 3 = first semester, 12 = second semester
  Future<List<CourseEntry>> fetchSchedule(
    String studentId,
    int year,
    int term,
  ) async {
    final referer =
        'https://jwzx.zjxu.edu.cn/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html'
        '?gnmkdm=N2151&layout=default&su=$studentId';

    final resp = await _dio.post<dynamic>(
      '/kbcx/xskbcx_cxXsKb.html',
      queryParameters: {'gnmkdm': 'N2151', 'su': studentId},
      data: 'xnm=$year&xqm=$term&kzlx=ck',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        validateStatus: (status) => status != null && status < 1000,
        headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
      ),
    );

    final statusCode = resp.statusCode ?? 0;
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('课表接口异常（状态码：$statusCode）');
    }

    final data = resp.data;
    if (data is! Map<String, dynamic>) {
      final raw = data?.toString() ?? '';
      if (_looksLikeLoginExpired(raw)) {
        throw const ScheduleAuthExpiredException();
      }
      throw const ScheduleRequestException('课表返回数据格式异常');
    }

    final message = data['message']?.toString() ?? '';
    if (_looksLikeLoginExpired(message)) {
      throw const ScheduleAuthExpiredException();
    }

    final kbList = data['kbList'] as List<dynamic>? ?? [];
    return kbList
        .cast<Map<String, dynamic>>()
        .map(CourseEntry.fromJson)
        .toList();
  }

  Future<List<CourseCancellationRule>> fetchCancellationRules(
    String studentId,
  ) async {
    final referer = 'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html';
    final resp = await _dio.post<String>(
      '/xtgl/index_cxAreaThree.html',
      queryParameters: {
        'localeKey': 'zh_CN',
        'gnmkdm': 'index',
        'su': studentId,
      },
      options: Options(
        responseType: ResponseType.plain,
        contentType: 'application/x-www-form-urlencoded;charset=UTF-8',
        validateStatus: (status) => status != null && status < 1000,
        headers: {'Referer': referer, 'X-Requested-With': 'XMLHttpRequest'},
      ),
    );

    final statusCode = resp.statusCode ?? 0;
    if (statusCode == 901 || statusCode == 302 || statusCode == 303) {
      throw const ScheduleAuthExpiredException();
    }
    if (statusCode >= 400) {
      throw ScheduleRequestException('课表调停课接口异常（状态码：$statusCode）');
    }

    final html = resp.data ?? '';
    if (_looksLikeLoginExpired(html)) {
      throw const ScheduleAuthExpiredException();
    }
    return _parseCancellationRules(html);
  }

  List<CourseCancellationRule> _parseCancellationRules(String html) {
    final rules = <CourseCancellationRule>[];
    final seen = <String>{};
    final messagePattern = RegExp(r'data-tkxx="([^"]+)"');

    for (final match in messagePattern.allMatches(html)) {
      final encodedMessage = match.group(1) ?? '';
      final message = _decodeHtmlEntities(encodedMessage);
      if (!message.contains('调课提醒') && !message.contains('停课提醒')) {
        continue;
      }

      final lessonInfo = _extractFirstLessonInfo(message);
      if (lessonInfo == null) continue;

      final courseName = _extractCourseName(message);
      final signature = [
        lessonInfo.week,
        lessonInfo.weekday,
        lessonInfo.startLesson,
        lessonInfo.endLesson,
        courseName ?? '',
      ].join('_');
      if (!seen.add(signature)) continue;

      rules.add(
        CourseCancellationRule(
          week: lessonInfo.week,
          weekday: lessonInfo.weekday,
          startLesson: lessonInfo.startLesson,
          endLesson: lessonInfo.endLesson,
          courseName: courseName,
        ),
      );
    }
    return rules;
  }

  _LessonInfo? _extractFirstLessonInfo(String message) {
    final pattern = RegExp(
      r'第\s*(\d+)\s*周\s*星期([一二三四五六日天])\s*第\s*(\d+)(?:\s*[-~]\s*(\d+))?\s*节',
    );
    final match = pattern.firstMatch(message);
    if (match == null) return null;

    final week = int.tryParse(match.group(1) ?? '');
    final weekday = _weekdayToInt(match.group(2) ?? '');
    final startLesson = int.tryParse(match.group(3) ?? '');
    final endLesson = int.tryParse(match.group(4) ?? match.group(3) ?? '');
    if (week == null ||
        weekday == null ||
        startLesson == null ||
        endLesson == null) {
      return null;
    }
    return _LessonInfo(
      week: week,
      weekday: weekday,
      startLesson: startLesson,
      endLesson: endLesson,
    );
  }

  String? _extractCourseName(String message) {
    final adjustMatch = RegExp(r'上的(.+?)课程调课').firstMatch(message);
    if (adjustMatch != null) {
      final name = adjustMatch.group(1)?.trim() ?? '';
      if (name.isNotEmpty) return name;
    }

    final stopMatch = RegExp(r'对课程(.+?)进行停课').firstMatch(message);
    if (stopMatch != null) {
      final name = stopMatch.group(1)?.trim() ?? '';
      if (name.isNotEmpty) return name;
    }

    final stopMatchAlt = RegExp(r'上的(.+?)课程停课').firstMatch(message);
    if (stopMatchAlt != null) {
      final name = stopMatchAlt.group(1)?.trim() ?? '';
      if (name.isNotEmpty) return name;
    }
    return null;
  }

  int? _weekdayToInt(String text) {
    return switch (text) {
      '一' => 1,
      '二' => 2,
      '三' => 3,
      '四' => 4,
      '五' => 5,
      '六' => 6,
      '日' || '天' => 7,
      _ => null,
    };
  }

  String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
  }

  bool _looksLikeLoginExpired(String text) {
    final value = text.toLowerCase();
    return value.contains('登录') ||
        value.contains('登陆') ||
        value.contains('session') ||
        value.contains('expired') ||
        value.contains('请先登录') ||
        value.contains('重新登录');
  }
}
