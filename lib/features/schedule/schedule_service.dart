import 'package:dio/dio.dart';

import '../../core/network/dio_client.dart';
import 'schedule_model.dart';

class ScheduleService {
  ScheduleService._();
  static final ScheduleService instance = ScheduleService._();

  final _dio = DioClient.instance.dio;

  /// [term]: 3 = first semester, 12 = second semester
  Future<List<CourseEntry>> fetchSchedule(
    String studentId,
    int year,
    int term,
  ) async {
    final referer =
        'https://jwzx.zjxu.edu.cn/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html'
        '?gnmkdm=N2151&layout=default&su=$studentId';

    final resp = await _dio.post<Map<String, dynamic>>(
      '/kbcx/xskbcx_cxXsKb.html',
      queryParameters: {'gnmkdm': 'N2151', 'su': studentId},
      data: 'xnm=$year&xqm=$term&kzlx=ck',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: {
          'Referer': referer,
          'X-Requested-With': 'XMLHttpRequest',
        },
      ),
    );

    final kbList = resp.data?['kbList'] as List<dynamic>? ?? [];
    return kbList
        .cast<Map<String, dynamic>>()
        .map(CourseEntry.fromJson)
        .toList();
  }
}
