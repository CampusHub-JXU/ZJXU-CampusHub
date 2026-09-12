import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_html_parser.dart';

String _fixture(String name) =>
    File('test/features/physical_test/fixtures/$name').readAsStringSync();

void main() {
  final menuHtml = _fixture('login_menu_main_jsp.html');
  final currentHtml = _fixture('current_score_healthscore.html');
  final unavailableCurrentHtml = _fixture(
    'current_score_unavailable_healthscore.html',
  );
  final yearListHtml = _fixture('year_list_score_total.html');
  final detailHtml = _fixture('score_detail_score_details.html');

  group('identity parsing', () {
    test('reads hidden stuNo / schoolid from the menu page', () {
      final identity = parsePhysicalTestIdentity(menuHtml);

      expect(identity.stuNo, 'VEVTVF9TVFVERU5UXzAwMDE=');
      expect(identity.schoolid, 'TEST_SCHOOL_0001');
    });

    test('rejects empty / literal null / base64 null identity values', () {
      for (final badValue in ['', 'null', 'NULL', ' bnVsbA== ']) {
        final html =
            '<html><body><form><input type="hidden" name="stuNo" '
            'value="$badValue"/><input type="hidden" name="schoolid" '
            'value="TEST_SCHOOL_0001"/></form></body></html>';
        expect(
          () => parsePhysicalTestIdentity(html),
          throwsA(isA<StateError>()),
          reason: 'stuNo=$badValue should be rejected',
        );
      }

      expect(
        () => parsePhysicalTestIdentity(
          '<html><body><form><input type="hidden" name="stuNo" '
          'value="VEVTVF9TVFVERU5UXzAwMDE="/><input type="hidden" '
          'name="schoolid" value="null"/></form></body></html>',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('score page parsing', () {
    test('parses the current score fixture', () {
      final record = parsePhysicalTestScorePage(currentHtml);

      expect(record.academicYear, '2025-2026-2');
      expect(record.totalScore, '55.0');
      expect(record.grade, '及格');
      expect(record.items, hasLength(8));

      final height = record.items.first;
      expect(height.name, '身高');
      expect(height.result, '170.0 厘米');
      expect(height.score, '');
      expect(height.level, '');

      final weight = record.items[1];
      expect(weight.name, '体重');
      expect(weight.result, '60.0 公斤');
      expect(weight.score, '100');
      expect(weight.level, '正常');

      final run = record.items.last;
      expect(run.name, '1000米跑');
      expect(run.result, '4.00 分钟');
      expect(run.score, '75');
      expect(run.level, '及格');
    });

    test('parses the detail fixture with its own year and totals', () {
      final record = parsePhysicalTestScorePage(detailHtml);

      expect(record.academicYear, '2025-2026-1');
      expect(record.totalScore, '52.0');
      expect(record.grade, '及格');
      expect(record.items, hasLength(8));
      expect(record.items.first.name, '身高');
      expect(record.items.first.result, '170.5 厘米');
      expect(record.items[1].score, '100');
    });

    test('unrecognized page structure throws instead of no records', () {
      expect(
        () => parsePhysicalTestScorePage(
          '<html><body><p>暂未开放查询</p></body></html>',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => parsePhysicalTestScorePage(
          '<html><body><table><tr><td>体测项目</td></tr></table></body>'
          '</html>',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('unavailable current page is a neutral null, strict parse fails', () {
      expect(tryParsePhysicalTestScorePage(unavailableCurrentHtml), isNull);
      expect(
        () => parsePhysicalTestScorePage(unavailableCurrentHtml),
        throwsA(isA<StateError>()),
        reason: '严格解析不得把未开放页当作无成绩',
      );
    });

    test('unavailable marker does not mask a real score page', () {
      final html = currentHtml.replaceFirst('<body>', '<body><p>暂未开放查询</p>');
      final record = tryParsePhysicalTestScorePage(html);

      expect(record, isNotNull);
      expect(record!.totalScore, '55.0');
      expect(record.items, hasLength(8));
    });

    test('unknown / damaged html still throws instead of neutral null', () {
      for (final html in [
        '<html><body><div>服务升级中</div></body></html>',
        '<html><body><table><tr><td>体测项目</td></tr></table></body>'
            '</html>',
      ]) {
        expect(
          () => tryParsePhysicalTestScorePage(html),
          throwsA(isA<StateError>()),
          reason: 'unknown structure must stay an error: $html',
        );
      }
    });
  });

  group('year list parsing', () {
    test('parses entries and keeps raw detail links', () {
      final entries = parsePhysicalTestYearList(yearListHtml);

      expect(entries, hasLength(2));
      expect(entries.first.academicYear, '2025-2026-1');
      expect(entries.first.totalScore, '55.0');
      expect(entries.first.grade, '及格');
      expect(
        entries.first.detailHref,
        '/spQuery?method=scoreDetails&schoolid=TEST_SCHOOL_0001'
        '&stuNo=VEVTVF9TVFVERU5UXzAwMDE=&year=2025-2026&term=1',
      );

      expect(entries.last.academicYear, '2025-2026-2');
      expect(entries.last.totalScore, '57.0');
      expect(entries.last.detailHref, contains('term=2'));
    });

    test('empty tbody is a legal empty list', () {
      final entries = parsePhysicalTestYearList(
        '<html><body><table><thead><tr><th>学年</th></tr></thead>'
        '<tbody></tbody></table></body></html>',
      );

      expect(entries, isEmpty);
    });

    test('page without the year table throws', () {
      expect(
        () => parsePhysicalTestYearList(currentHtml),
        throwsA(isA<StateError>()),
      );
    });
  });
}
