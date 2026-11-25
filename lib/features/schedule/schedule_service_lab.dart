part of 'schedule_service.dart';

// 学生课表页的 xskbcx.js / BaseJqGrid 配置：独立的只读分页查询。
const _labSchedulePath = '/xssygl/sykbcx_cxSykbcxxsIndex.html';
const _labPageSize = 50; // 教务分页器支持的大小
const _maxLabPages = 20;

extension on ScheduleService {
  /// 附表复用已验证的请求路线，不单独恢复登录或切换线路。
  /// null 表示取数未完成，不等同于教务返回空附表。
  Future<List<CourseEntry>?> _loadLabSchedule({
    required ZhengfangMode mode,
    required String studentId,
    required int revision,
    required int year,
    required int term,
  }) async {
    final auth = ZhengfangAuth.instance;
    final referer = _scheduleReferer(auth, mode, studentId);
    final courses = <CourseEntry>[];
    final rowIds = <String>{};
    int? totalPages;
    int? totalRows;
    var rowsRead = 0;
    try {
      for (var page = 1; page <= _maxLabPages; page++) {
        if (!_isIdentityCurrent(studentId, revision)) return null;
        final response = await auth
            .academicDioFor(mode)
            .post<dynamic>(
              auth.buildPortalUrl(_labSchedulePath, mode: mode),
              queryParameters: {
                'doType': 'query',
                'gnmkdm': 'N2151',
                'su': studentId,
              },
              data:
                  'xnm=$year&xqm=$term&kzlx=ck&_search=false'
                  '&queryModel.showCount=$_labPageSize&queryModel.currentPage=$page'
                  '&queryModel.sortName=&queryModel.sortOrder=asc',
              options: Options(
                contentType: 'application/x-www-form-urlencoded',
                followRedirects: false,
                headers: {
                  'Referer': referer,
                  'X-Requested-With': 'XMLHttpRequest',
                },
              ),
            );
        if (!_isIdentityCurrent(studentId, revision) ||
            response.statusCode != 200 ||
            AcademicAuthGuard.isAuthExpiredResponse(response)) {
          return null;
        }
        final data = response.data;
        if (data is! Map<String, dynamic>) return null;
        final items = data['items'];
        final current = int.tryParse('${data['currentPage']}');
        final pages = int.tryParse('${data['totalPage']}');
        final rows = int.tryParse('${data['totalResult']}');
        if (items is! List ||
            pages == null ||
            rows == null ||
            pages < 0 ||
            pages > _maxLabPages ||
            rows < 0 ||
            (totalPages != null &&
                (totalPages != pages || totalRows != rows))) {
          return null;
        }
        if (page == 1 &&
            rows == 0 &&
            items.isEmpty &&
            pages <= 1 &&
            (current == 0 || current == 1)) {
          return const [];
        }
        if (current != page || page > pages || items.isEmpty) return null;
        totalPages = pages;
        totalRows = rows;
        rowsRead += items.length;
        if (rowsRead > rows) return null;
        for (final row in items) {
          if (row is! Map<String, dynamic>) return null;
          final id = row['xmz_id']?.toString() ?? '';
          if (id.isNotEmpty && !rowIds.add(id)) return null;
          final course = _parseLabRow(row);
          if (course != null) courses.add(course);
        }
        if (page == pages) return rowsRead == rows ? courses : null;
      }
    } on DioException {
      return null;
    } on FormatException {
      return null;
    }
    return null;
  }
}

final _labTime = RegExp(
  r'^(?:星期|周)([一二三四五六日天])\s*[\[［（(]\s*'
  r'(\d{1,2})(?:\s*[-–－]\s*(\d{1,2}))?\s*节\s*(\d{1,2})\s*周\s*'
  r'[\]］）)]\s*(.*)$',
);

CourseEntry? _parseLabRow(Map<String, dynamic> row) {
  String text(String key) => row[key]?.toString().trim() ?? '';
  final time = text('sksjdd');
  if (time.isEmpty || time == '未安排' || time == '未排时间') return null;
  final match = _labTime.firstMatch(time);
  final name = text('kcmc');
  if (match == null || name.isEmpty) {
    throw const FormatException('Unrecognized lab timetable row');
  }
  final start = int.parse(match[2]!);
  final end = int.parse(match[3] ?? match[2]!);
  final week = int.parse(match[4]!);
  if (week < 1 || start < 1 || end < start || end > scheduleSlotCount) {
    throw const FormatException('Invalid lab timetable slot');
  }
  final site = text('dycdxq').split('/').map((part) => part.trim()).toList();
  final room = site.length >= 2 && site[1].isNotEmpty
      ? site[1]
      : (match[5]!.isNotEmpty ? match[5]! : site.first);
  return CourseEntry(
    courseName: name,
    courseCode: text('kch'),
    labProject: text('xmmc'),
    teacherName: text('jsxm'),
    weekday: _weekdayToInt(match[1]!)!,
    startLesson: start,
    endLesson: end,
    weekRange: '$week周',
    classroom: room,
    campus: site.length >= 3 ? site[2] : '',
    typeSymbol: '◇',
    fromLabSchedule: true,
  );
}

List<CourseEntry> _mergeLabSchedule(
  List<CourseEntry> main,
  List<CourseEntry> labs,
) {
  if (labs.isEmpty) return main;
  final replacedWeeks = <CourseEntry, Set<int>>{};
  final additions = <CourseEntry>[];
  final seen =
      <
        (String, String, String, String, int, int, int, String, String, String)
      >{};
  for (final lab in labs) {
    final week = int.parse(lab.weekRange.replaceAll('周', ''));
    final candidates = main.where((course) {
      if (course.weekday != lab.weekday ||
          course.startLesson != lab.startLesson ||
          course.endLesson != lab.endLesson ||
          !course.isInWeek(week) ||
          !const {'◇', '●', '★'}.contains(course.typeSymbol)) {
        return false;
      }
      if (course.courseCode.isNotEmpty && lab.courseCode.isNotEmpty) {
        return course.courseCode == lab.courseCode;
      }
      return course.courseName.replaceAll(RegExp(r'\s'), '') ==
          lab.courseName.replaceAll(RegExp(r'\s'), '');
    }).toList();
    // 只替换同课、同节次的唯一实践类条目，不猜测同名课的归属。
    final existing = candidates.length == 1 ? candidates.single : null;
    if (existing != null) (replacedWeeks[existing] ??= {}).add(week);
    final entry = _copyLabCourse(
      lab,
      courseName: existing?.courseName,
      teacherName: lab.teacherName.isEmpty ? existing?.teacherName : null,
      classroom: lab.classroom.isEmpty ? existing?.classroom : null,
      campus: lab.campus.isEmpty ? existing?.campus : null,
      typeSymbol: existing?.typeSymbol,
      hasScheduleChange: existing?.hasScheduleChange,
    );
    if (seen.add((
      entry.courseCode,
      entry.courseName,
      entry.labProject,
      entry.weekRange,
      entry.weekday,
      entry.startLesson,
      entry.endLesson,
      entry.teacherName,
      entry.classroom,
      entry.campus,
    ))) {
      additions.add(entry);
    }
  }
  final retained = <CourseEntry>[];
  for (final course in main) {
    final excluded = replacedWeeks[course];
    if (excluded == null) {
      retained.add(course);
      continue;
    }
    // 只裁掉实际匹配的周次，保留主表的其余排课。
    final remaining = course.weekRangeExcluding(excluded);
    if (remaining != null) {
      retained.add(_copyLabCourse(course, weekRange: remaining));
    }
  }
  return [...retained, ...additions];
}

CourseEntry _copyLabCourse(
  CourseEntry course, {
  String? courseName,
  String? teacherName,
  String? classroom,
  String? campus,
  String? typeSymbol,
  String? weekRange,
  bool? hasScheduleChange,
}) => CourseEntry(
  courseName: courseName ?? course.courseName,
  courseCode: course.courseCode,
  labProject: course.labProject,
  teacherName: teacherName ?? course.teacherName,
  weekday: course.weekday,
  startLesson: course.startLesson,
  endLesson: course.endLesson,
  weekRange: weekRange ?? course.weekRange,
  classroom: classroom ?? course.classroom,
  campus: campus ?? course.campus,
  typeSymbol: typeSymbol ?? course.typeSymbol,
  hasScheduleChange: hasScheduleChange ?? course.hasScheduleChange,
  fromLabSchedule: course.fromLabSchedule,
);
