import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_relevance.dart';

Notice _notice(String title, {String? date}) => Notice(
  title: title,
  url: 'https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=title-hash',
  category: '通知公告',
  date: date,
);

void main() {
  group('inferEnrollmentYearFromId', () {
    test('reads leading 20XX as enrollment year', () {
      expect(NoticeRelevance.inferEnrollmentYearFromId('20230101'), 2023);
      expect(NoticeRelevance.inferEnrollmentYearFromId('20262468'), 2026);
    });

    test('returns null without a plausible year prefix', () {
      expect(NoticeRelevance.inferEnrollmentYearFromId('32123456'), isNull);
      expect(NoticeRelevance.inferEnrollmentYearFromId(''), isNull);
      expect(NoticeRelevance.inferEnrollmentYearFromId('19980101'), isNull);
    });
  });

  group('title markers', () {
    test('extracts explicit cohort years', () {
      expect(NoticeRelevance.extractCohortYears('关于2024级新生报到安排的通知'), {2024});
      expect(NoticeRelevance.extractCohortYears('2023、2024级学生选课通知'), {
        2023,
        2024,
      });
      expect(NoticeRelevance.extractCohortYears('面向全体学生的通知'), isEmpty);
    });

    test('extracts academic year end years', () {
      expect(
        NoticeRelevance.extractAcademicYearEnds('关于公布2025-2026学年第二学期缓补考安排的通知'),
        {2026},
      );
      expect(NoticeRelevance.extractAcademicYearEnds('期初教学检查通知'), isEmpty);
    });
  });

  group('isRelevant', () {
    test('explicit cohort list decides when present', () {
      const title2024 = '关于2024级新生军训安排的通知';
      expect(NoticeRelevance.isRelevant(_notice(title2024), 2024), isTrue);
      expect(NoticeRelevance.isRelevant(_notice(title2024), 2023), isFalse);
      expect(
        NoticeRelevance.isRelevant(_notice(title2024), null),
        isTrue,
        reason: '年级未知时宁多勿漏',
      );
    });

    test('retrospective academic years before enrollment are irrelevant', () {
      const retrospective = '关于公布2024-2025学年第二学期缓补考考试安排的通知';
      expect(NoticeRelevance.isRelevant(_notice(retrospective), 2026), isFalse);
      expect(NoticeRelevance.isRelevant(_notice(retrospective), 2025), isTrue);
      expect(NoticeRelevance.isRelevant(_notice(retrospective), 2024), isTrue);
    });

    test('generic notices stay relevant for everyone', () {
      const generic = '关于2026-2027学年第一学期各类选课工作的通知';
      expect(NoticeRelevance.isRelevant(_notice(generic), 2023), isTrue);
      expect(NoticeRelevance.isRelevant(_notice(generic), 2026), isTrue);
    });
  });

  group('orderByRelevanceThenDate', () {
    test(
      'relevant first (date desc), out-of-cohort sinks, dates still desc',
      () {
        final notices = [
          _notice('面向2026级的新生通知', date: '2026-09-04'),
          _notice('普通通知甲', date: '2026-09-01'),
          _notice('面向2024级的评优通知', date: '2026-09-03'),
          _notice('普通通知乙', date: '2026-08-30'),
        ];
        final ordered = NoticeRelevance.orderByRelevanceThenDate(notices, 2023);

        expect(ordered.map((n) => n.title).toList(), [
          '普通通知甲',
          '普通通知乙',
          '面向2026级的新生通知',
          '面向2024级的评优通知',
        ]);
      },
    );

    test('unknown enrollment year keeps pure date order', () {
      final notices = [
        _notice('旧通知', date: '2026-07-01'),
        _notice('新通知', date: '2026-09-01'),
      ];
      expect(
        NoticeRelevance.orderByRelevanceThenDate(
          notices,
          null,
        ).map((n) => n.title),
        ['新通知', '旧通知'],
      );
    });
  });

  group('Notice.sortByDateDescStable', () {
    test('sorts newest first, sinks missing dates, keeps same-date order', () {
      final a = _notice('a', date: '2026-09-01');
      final a2 = _notice('a2', date: '2026-09-01');
      final newest = _notice('newest', date: '2026-09-04');
      final oldest = _notice('oldest', date: '2026-07-13');
      final noDate = _notice('noDate');

      final sorted = Notice.sortByDateDescStable([
        a,
        oldest,
        newest,
        noDate,
        a2,
      ]);

      expect(sorted.map((n) => n.title).toList(), [
        'newest',
        'a',
        'a2',
        'oldest',
        'noDate',
      ]);
    });

    test('tolerates slashed and dotted date text via normalized field', () {
      expect(_notice('x', date: '2026/9/4').parsedDate, isNotNull);
      expect(_notice('x', date: '2026.9.4').parsedDate, isNotNull);
      expect(_notice('x', date: '').parsedDate, isNull);
    });
  });
}
