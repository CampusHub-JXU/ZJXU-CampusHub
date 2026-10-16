import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/academic/exam_model.dart';
import 'package:jxu_campus_hub/core/academic/schedule_change_rule.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/semester/china_public_holidays.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:jxu_campus_hub/features/home/models/example_campus_snapshot.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_accent.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_projection.dart';

CourseEntry _course(
  String name, {
  required int weekday,
  required int start,
  required int end,
  String classroom = '',
  String campus = '',
  String weekRange = '1-16周',
}) => CourseEntry(
  courseName: name,
  teacherName: '老师',
  weekday: weekday,
  startLesson: start,
  endLesson: end,
  weekRange: weekRange,
  classroom: classroom,
  campus: campus,
  typeSymbol: '',
);

ExamEntry _exam(
  String name,
  DateTime? date, {
  String start = '',
  String end = '',
  String location = '',
  String campus = '',
}) => ExamEntry(
  courseName: name,
  courseCode: '',
  examTimeRaw: '',
  examDate: date,
  startTime: start,
  endTime: end,
  location: location,
  campus: campus,
  seatNumber: '',
  examName: '',
  department: '',
  isRetake: false,
  academicYear: '',
  semester: '',
  weekday: 0,
  weekNumber: 0,
);

const _term = ScheduleTermContext(academicYear: 2026, term: 3);

/// 2026-10-12（周一）是第 7 周（开学日 2026-09-01，第 1 周周一 08-31）。
final _now = DateTime(2026, 10, 12, 7, 58);
final _semesterStart = DateTime(2026, 9, 1);

List<CourseEntry> _courses() => [
  _course('高等数学', weekday: 1, start: 1, end: 2, classroom: '7-201'),
  _course('线性代数', weekday: 2, start: 1, end: 1, classroom: '3-105'),
  _course('大学英语', weekday: 3, start: 3, end: 4, classroom: '教B-102'),
  _course('节日课', weekday: 4, start: 1, end: 2, classroom: '1-1'),
  _course('物理实验', weekday: 5, start: 11, end: 12, campus: '梁林校区'),
];

final _rules = [
  // 周二第 1 节被取消 → 当天无课（停课）。
  CourseChangeRule(
    type: CourseChangeType.cancel,
    originalLesson: const CourseLessonSlot(
      week: 7,
      weekday: 2,
      startLesson: 1,
      endLesson: 1,
    ),
    courseName: '线性代数',
    termContext: _term,
  ),
  // 周三 3-4 节调到周六 6-7 节。
  CourseChangeRule(
    type: CourseChangeType.reschedule,
    originalLesson: const CourseLessonSlot(
      week: 7,
      weekday: 3,
      startLesson: 3,
      endLesson: 4,
    ),
    targetLesson: const CourseLessonSlot(
      week: 7,
      weekday: 6,
      startLesson: 6,
      endLesson: 7,
    ),
    courseName: '大学英语',
    classroom: '教B-203',
    termContext: _term,
  ),
];

List<Map<String, Object?>> _days({
  DateTime? now,
  bool hasCourseData = true,
  DateTime? semesterStart,
}) => buildCampusWidgetDays(
  now: now ?? _now,
  hasCourseData: hasCourseData,
  courses: _courses(),
  changeRules: _rules,
  semesterStartDate: semesterStart ?? _semesterStart,
);

List<Map<String, Object?>> _coursesOf(Map<String, Object?> day) =>
    (day['courses'] as List).cast<Map<String, Object?>>();

void _expectNoNullStrings(Object? value) {
  if (value is Map) {
    value.values.forEach(_expectNoNullStrings);
  } else if (value is List) {
    value.forEach(_expectNoNullStrings);
  } else if (value is String) {
    expect(value, isNot('null'));
    expect(value, isNot('undefined'));
  }
}

void main() {
  setUp(() {
    // 15 日设为法定假期（固定数据，不依赖真实表）。
    debugChinaPublicHolidaysOverride = [
      ChinaPublicHoliday('测试节', DateTime(2026, 10, 15), DateTime(2026, 10, 15)),
    ];
  });

  tearDown(() => debugChinaPublicHolidaysOverride = null);

  test('fromPresentation 生成无凭据投影并可序列化', () {
    final generatedAt = DateTime(2026, 9, 12, 8, 30);
    final projection = CampusWidgetProjection.fromPresentation(
      ExampleCampusSnapshot.presentation,
      generatedAt: generatedAt,
      unreadNoticeCount: 3,
    );

    expect(projection.hasTodayCourses, isTrue);
    expect(projection.todayCourses, isNotEmpty);
    expect(projection.heroCourseName, '高等数学 C2');
    expect(projection.hasCampusCardData, isTrue);
    expect(projection.campusCardBalance, isNotEmpty);
    expect(projection.unreadNoticeCount, 3);

    final map = projection.toMap();
    // v2：本地时间、无时区后缀、无小数秒。
    expect(map['generatedAt'], '2026-09-12T08:30:00');
    expect(map['todayTitle'], isNotEmpty);
    expect(
      (map['todayCourses'] as List),
      hasLength(projection.todayCourses.length),
    );

    final keys = map.keys.join(',').toLowerCase();
    for (final secret in const [
      'cookie',
      'token',
      'password',
      'session',
      'credential',
      'student',
    ]) {
      expect(keys.contains(secret), isFalse, reason: '投影不得包含凭据字段: $secret');
    }
  });

  group('快照 v2 形状', () {
    Map<String, Object?> buildMap({
      List<Notice> notices = const [],
      String? light = '#8B1A2D',
      String? dark = '#E8A3AE',
    }) {
      final days = _days();
      return CampusWidgetProjection.fromPresentation(
        ExampleCampusSnapshot.presentation,
        generatedAt: _now,
        unreadNoticeCount: notices.length,
        days: days,
        exams: buildCampusWidgetExams(
          now: _now,
          exams: [
            _exam(
              '线性代数',
              DateTime(2026, 10, 20),
              start: '09:00',
              end: '11:00',
              location: '3-105',
            ),
          ],
        ),
        noticeItems: buildCampusWidgetNoticeItems(notices),
        accentLight: light,
        accentDark: dark,
      ).toMap();
    }

    test('schemaVersion、类型与 v1 兼容字段齐全', () {
      final map = buildMap(
        notices: [
          const Notice(
            title: '关于国庆放假的通知',
            url: 'https://example.invalid/1',
            category: '通知公告',
            date: '2026-10-15',
          ),
        ],
      );
      expect(map['schemaVersion'], 2);
      expect(map['generatedAt'], '2026-10-12T07:58:00');
      expect(map['emptyState'], isNull);
      expect(map['emptyStateText'], isNull);
      expect(map['weekLabel'], isA<String>());
      expect(map['days'], isA<List>());
      expect(map['exams'], isA<List>());
      final card = map['campusCard'] as Map;
      expect(card.keys, containsAll(['hasData', 'balance', 'low']));
      final electricity = map['electricity'] as Map;
      expect(electricity.keys, containsAll(['hasData', 'value', 'low']));
      expect(map['theme'], {'accentLight': '#8B1A2D', 'accentDark': '#E8A3AE'});
      final notices = map['notices'] as Map;
      expect(notices['unreadCount'], 1);
      expect(notices['items'], [
        {'title': '关于国庆放假的通知', 'publishedAt': '2026-10-15'},
      ]);

      // v1 兼容字段原样保留。
      for (final key in const [
        'heroHeadline',
        'heroTimeText',
        'heroCourseName',
        'heroLocationText',
        'todayCourses',
        'hasTodayCourses',
        'todayTitle',
        'nextExamCourseName',
        'nextExamTimeText',
        'nextExamLocationText',
        'campusCardBalance',
        'hasCampusCardData',
        'dormElectricity',
        'hasElectricityData',
        'unreadNoticeCount',
      ]) {
        expect(map.containsKey(key), isTrue, reason: 'v1 字段缺失: $key');
      }
      expect(map['heroCourseName'], '高等数学 C2');
    });

    test('无主题色时不带 theme；可 JSON 序列化且无 "null" 字符串', () {
      final map = buildMap(light: null, dark: null);
      expect(map.containsKey('theme'), isFalse);
      final decoded = jsonDecode(jsonEncode(map)) as Map<String, Object?>;
      expect(decoded['schemaVersion'], 2);
      _expectNoNullStrings(decoded);
    });
  });

  group('7 日课程 days', () {
    test('7 天连续、日期升序、含无课日；周次标签含星期', () {
      final days = _days();
      expect(days, hasLength(7));
      expect(
        [for (final d in days) d['date']],
        [
          '2026-10-12',
          '2026-10-13',
          '2026-10-14',
          '2026-10-15',
          '2026-10-16',
          '2026-10-17',
          '2026-10-18',
        ],
      );
      expect(days.first['weekLabel'], '第 7 周 · 周一');
      expect(days.last['weekLabel'], '第 7 周 · 周日');
      expect(_coursesOf(days.last), isEmpty);
      expect(days.last['holidayName'], isNull);
    });

    test('startAt/endAt 是绝对本地时间，且与 timeText 一致', () {
      final monday = _days().first;
      final course = _coursesOf(monday).single;
      expect(course, {
        'startAt': '2026-10-12T08:00:00',
        'endAt': '2026-10-12T09:25:00',
        'timeText': '08:00-09:25',
        'lessonText': '1-2 节',
        'courseName': '高等数学',
        'locationText': '7-201',
      });

      // 全部课程：HH:mm 与 timeText 两端一致，且 endAt > startAt。
      for (final day in _days()) {
        for (final c in _coursesOf(day)) {
          final start = (c['startAt'] as String).substring(11, 16);
          final end = (c['endAt'] as String).substring(11, 16);
          expect(c['timeText'], '$start-$end');
          expect(
            DateTime.parse(c['endAt'] as String)
                .isAfter(DateTime.parse(c['startAt'] as String)),
            isTrue,
          );
          expect(
            (c['startAt'] as String).startsWith(day['date'] as String),
            isTrue,
          );
        }
      }
    });

    test('调课 / 停课 / 节假日规则与首页同源生效', () {
      final days = _days();
      // 周二：课被取消 → 停课。
      expect(_coursesOf(days[1]), isEmpty);
      expect(days[1]['holidayName'], '停课');
      // 周三：课被调走 → 当天无课（与首页放假判定一致）。
      expect(_coursesOf(days[2]), isEmpty);
      // 周四：法定节假日 → 无课 + 节日名。
      expect(_coursesOf(days[3]), isEmpty);
      expect(days[3]['holidayName'], '测试节');
      // 周五：晚课，校区回退作为地点。
      final friday = _coursesOf(days[4]).single;
      expect(friday['startAt'], '2026-10-16T18:30:00');
      expect(friday['endAt'], '2026-10-16T19:55:00');
      expect(friday['locationText'], '梁林校区');
      // 周六：调课后的课出现在目标日，用通知里的目标教室。
      final saturday = _coursesOf(days[5]).single;
      expect(saturday['courseName'], '大学英语');
      expect(saturday['locationText'], '教B-203');
      expect(saturday['timeText'], '13:30-14:55');
      expect(saturday['lessonText'], '6-7 节');
    });

    test('同日多课按开始时间升序', () {
      final days = buildCampusWidgetDays(
        now: _now,
        hasCourseData: true,
        courses: [
          _course('下午课', weekday: 1, start: 6, end: 7, classroom: 'B'),
          _course('上午课', weekday: 1, start: 1, end: 2, classroom: 'A'),
        ],
        changeRules: const [],
        semesterStartDate: _semesterStart,
      );
      expect(_coursesOf(days.first).map((c) => c['courseName']), [
        '上午课',
        '下午课',
      ]);
    });

    test('学期之外的日子课程为空，周次标签只有星期', () {
      // 开学日在窗口之后：整个窗口都在教学周之前。
      final before = _days(semesterStart: DateTime(2026, 10, 26));
      expect(before.expand(_coursesOf), isEmpty);
      expect(before.first['weekLabel'], '周一');

      // 窗口跨越开学日：前半窗口为空，开学周起有课。
      final now = DateTime(2026, 10, 16, 8);
      final mixed = _days(now: now, semesterStart: DateTime(2026, 10, 21));
      expect(mixed.take(3).expand(_coursesOf), isEmpty); // 周五~周日
      expect(mixed[3]['weekLabel'], '第 1 周 · 周一');
      expect(_coursesOf(mixed[3]), isNotEmpty);

      // 学期结束之后。
      final after = _days(semesterStart: DateTime(2026, 3, 2));
      expect(after.expand(_coursesOf), isEmpty);
    });

    test('无课表数据（未登录 / 无缓存）时 courses 全空且不推断假期', () {
      final days = _days(hasCourseData: false);
      expect(days, hasLength(7));
      expect(days.expand(_coursesOf), isEmpty);
      expect(days.every((d) => d['holidayName'] == null), isTrue);
    });
  });

  group('emptyState', () {
    List<Map<String, Object?>> withCourse() => _days();
    List<Map<String, Object?>> noCourse() => _days(hasCourseData: false);

    CampusWidgetEmptyState? resolve({
      bool loggedIn = true,
      bool cache = true,
      bool before = false,
      bool after = false,
      List<Map<String, Object?>>? days,
    }) => resolveCampusWidgetEmptyState(
      courseLoggedIn: loggedIn,
      hasScheduleCache: cache,
      isBeforeSemesterStart: before,
      isAfterSemesterEnd: after,
      days: days ?? withCourse(),
    );

    test('各状态与提示文案', () {
      expect(resolve(), isNull);
      expect(
        resolve(loggedIn: false, cache: false, days: noCourse()),
        CampusWidgetEmptyState.notLoggedIn,
      );
      expect(
        resolve(cache: false, days: noCourse()),
        CampusWidgetEmptyState.noCache,
      );
      final days = _days(semesterStart: DateTime(2026, 10, 26));
      expect(
        resolve(before: true, days: days),
        CampusWidgetEmptyState.beforeSemester,
      );
      expect(
        resolve(after: true, days: _days(semesterStart: DateTime(2026, 3, 2))),
        CampusWidgetEmptyState.afterSemester,
      );
      expect(CampusWidgetEmptyState.notLoggedIn.text, '登录教务后显示课表');
      for (final state in CampusWidgetEmptyState.values) {
        expect(state.text, isNotEmpty);
      }
    });

    test('未开学但 7 天窗口内已有课时不算空', () {
      expect(resolve(before: true), isNull);
    });
  });

  group('exams', () {
    final now = DateTime(2026, 10, 12, 8);

    test('过滤已结束、无日期；按开始时间升序；最多 5 条', () {
      final result = buildCampusWidgetExams(
        now: now,
        exams: [
          _exam('已过期', DateTime(2026, 10, 10), start: '09:00', end: '11:00'),
          _exam('今早已结束', DateTime(2026, 10, 12), start: '07:00', end: '07:30'),
          _exam('无日期', null),
          _exam('晚', DateTime(2026, 10, 30), start: '14:00', end: '16:00'),
          _exam(
            '早',
            DateTime(2026, 10, 14),
            start: '14:00',
            end: '16:00',
            location: '3-105',
          ),
          _exam('同日上午', DateTime(2026, 10, 20), start: '09:00', end: '11:00'),
          _exam('同日下午', DateTime(2026, 10, 20), start: '14:00', end: '16:00'),
          _exam('x1', DateTime(2026, 11, 1), start: '09:00', end: '11:00'),
          _exam('x2', DateTime(2026, 11, 2), start: '09:00', end: '11:00'),
          _exam('x3', DateTime(2026, 11, 3), start: '09:00', end: '11:00'),
        ],
      );
      expect(result, hasLength(5));
      expect(result.map((e) => e['courseName']), [
        '早',
        '同日上午',
        '同日下午',
        '晚',
        'x1',
      ]);
      expect(result.first, {
        'startAt': '2026-10-14T14:00:00',
        'endAt': '2026-10-14T16:00:00',
        'timeText': '10月14日 14:00-16:00',
        'courseName': '早',
        'locationText': '3-105',
      });
    });

    test('只缓存一条考试时只输出一条；正在进行 / 无时间的当日考试保留', () {
      final one = buildCampusWidgetExams(
        now: now,
        exams: [
          _exam('唯一', DateTime(2026, 10, 20), start: '09:00', end: '11:00'),
        ],
      );
      expect(one, hasLength(1));

      // 只有开始时间：结束补为开始 + 2 小时。
      final startOnly = buildCampusWidgetExams(
        now: now,
        exams: [_exam('只有开始', DateTime(2026, 10, 20), start: '09:00')],
      );
      expect(startOnly.single['endAt'], '2026-10-20T11:00:00');

      final today = buildCampusWidgetExams(
        now: now,
        exams: [
          _exam('进行中', DateTime(2026, 10, 12), start: '07:30', end: '09:30'),
          _exam('时间未定', DateTime(2026, 10, 12)),
        ],
      );
      expect(today.map((e) => e['courseName']), ['时间未定', '进行中']);
      // 无时间的考试显式补到当天 23:59:59，原生不会按自己的默认提前判结束。
      expect(today.first['endAt'], '2026-10-12T23:59:59');
      expect(today.first['timeText'], '10月12日');
      expect(today.first['locationText'], '地点待定');
    });

    test('空列表', () {
      expect(buildCampusWidgetExams(now: now, exams: const []), isEmpty);
    });
  });

  group('notices', () {
    test('最多 5 条、保持顺序；日期规范化为 YYYY-MM-DD，缺失为空串', () {
      final items = buildCampusWidgetNoticeItems([
        for (var i = 1; i <= 8; i++)
          Notice(
            title: '通知 $i',
            url: 'https://example.invalid/$i',
            category: '通知公告',
            date: i == 2 ? null : '2026/10/$i',
          ),
      ]);
      expect(items, hasLength(5));
      expect(items.first, {'title': '通知 1', 'publishedAt': '2026-10-01'});
      expect(items[1], {'title': '通知 2', 'publishedAt': ''});
    });
  });

  group('强调色 theme', () {
    test('默认色相：与 App 主题 primary 一致且达标', () {
      final accents = resolveCampusWidgetAccents(const Color(0xFF8B1A2D));
      expect(accents.light, matches(RegExp(r'^#[0-9A-F]{6}$')));
      expect(accents.dark, matches(RegExp(r'^#[0-9A-F]{6}$')));
      expect(accents.light, '#8B1A2D'); // 浅色主题 primary = 种子色，已达标
    });

    for (final entry in {
      '很浅的自定义色 #FFF59D': const Color(0xFFFFF59D),
      '很深的自定义色 #0B0C10': const Color(0xFF0B0C10),
      '纯黄 #FFFF00': const Color(0xFFFFFF00),
      '纯白 #FFFFFF': const Color(0xFFFFFFFF),
      '纯黑 #000000': const Color(0xFF000000),
      '亮青 #00E5FF': const Color(0xFF00E5FF),
    }.entries) {
      test('对比度兜底：${entry.key}', () {
        final accents = resolveCampusWidgetAccents(entry.value);
        Color parse(String hex) =>
            Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
        expect(
          campusWidgetContrastRatio(
            parse(accents.light),
            campusWidgetCardLight,
          ),
          greaterThanOrEqualTo(4.5),
          reason: 'light ${accents.light}',
        );
        expect(
          campusWidgetContrastRatio(parse(accents.dark), campusWidgetCardDark),
          greaterThanOrEqualTo(4.5),
          reason: 'dark ${accents.dark}',
        );
        // 「进行中」行：强调色文字画在叠了强调底的行上，同样要达标。
        Color tinted(Color accent, Color card, double alpha) =>
            Color.alphaBlend(accent.withValues(alpha: alpha), card);
        final light = parse(accents.light);
        final dark = parse(accents.dark);
        expect(
          campusWidgetContrastRatio(
            light,
            tinted(light, campusWidgetCardLight, campusWidgetTintAlphaLight),
          ),
          greaterThanOrEqualTo(4.5),
          reason: 'light tinted ${accents.light}',
        );
        expect(
          campusWidgetContrastRatio(
            dark,
            tinted(dark, campusWidgetCardDark, campusWidgetTintAlphaDark),
          ),
          greaterThanOrEqualTo(4.5),
          reason: 'dark tinted ${accents.dark}',
        );
      });
    }

    test('ensureCampusWidgetContrast 已达标时不变，且保持色相', () {
      const ok = Color(0xFF8B1A2D);
      expect(
        ensureCampusWidgetContrast(
          ok,
          background: campusWidgetCardLight,
          darken: true,
        ),
        ok,
      );
      final fixed = ensureCampusWidgetContrast(
        const Color(0xFFFFF59D),
        background: campusWidgetCardLight,
        darken: true,
      );
      expect(
        (HSLColor.fromColor(fixed).hue -
                HSLColor.fromColor(const Color(0xFFFFF59D)).hue)
            .abs(),
        lessThan(3),
      );
    });
  });

  test('formatCampusWidgetDateTime 无时区后缀、无小数秒', () {
    expect(
      formatCampusWidgetDateTime(DateTime(2026, 10, 16, 7, 58, 5, 123)),
      '2026-10-16T07:58:05',
    );
  });
}
