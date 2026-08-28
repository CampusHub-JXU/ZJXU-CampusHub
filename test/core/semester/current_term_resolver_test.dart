import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/semester/current_term_resolver.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CurrentTermResolver.parseCurrentTermFromIndexHtml', () {
    test('parses selected options from standard zfsoft markup', () {
      const html = '''
<html><body>
<select id="xnm" name="xnm" class="form-control" width="120px">
  <option value="2024">2024</option>
  <option value="2025">2025</option>
  <option value="2026" selected="selected">2026</option>
</select>
<select id="xqm" name="xqm" class="form-control" width="120px">
  <option value="3" selected="selected">第1学期</option>
  <option value="12">第2学期</option>
</select>
</body></html>
''';

      final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
      expect(context, const ScheduleTermContext(academicYear: 2026, term: 3));
    });

    test('parses unquoted selected attribute placed before value', () {
      const html = '''
<select id="xnm">
  <option selected value='2025'>2025</option>
</select>
<select id="xqm">
  <option selected value='12'>第2学期</option>
</select>
''';

      final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
      expect(context, const ScheduleTermContext(academicYear: 2025, term: 12));
    });

    test(
      'falls back to jQuery val() assignment when options miss selected',
      () {
        const html = '''
<select id="xnm">
  <option value="2025">2025</option>
</select>
<select id="xqm">
  <option value="3">第1学期</option>
</select>
<script>
jQuery("#xnm").val("2025");
jQuery("#xqm").val("12");
</script>
''';

        final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
        expect(
          context,
          const ScheduleTermContext(academicYear: 2025, term: 12),
        );
      },
    );

    test('does not confuse xnm with ids like xnm2', () {
      const html = '''
<select id="xnm2" name="xnm2">
  <option value="9999" selected="selected">9999</option>
</select>
<select id="xnm">
  <option value="2026" selected="selected">2026</option>
</select>
<select id="xqm">
  <option value="3" selected="selected">第1学期</option>
</select>
''';

      final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
      expect(context, const ScheduleTermContext(academicYear: 2026, term: 3));
    });

    test('returns null when selects are missing', () {
      expect(
        CurrentTermResolver.parseCurrentTermFromIndexHtml('<p>登录</p>'),
        isNull,
      );
      expect(CurrentTermResolver.parseCurrentTermFromIndexHtml(''), isNull);
    });

    test('returns null on out-of-range year or unknown term code', () {
      const badYear = '''
<select id="xnm"><option value="1899" selected="selected">1899</option></select>
<select id="xqm"><option value="3" selected="selected">第1学期</option></select>
''';
      const badTerm = '''
<select id="xnm"><option value="2026" selected="selected">2026</option></select>
<select id="xqm"><option value="16" selected="selected">第3学期</option></select>
''';

      expect(
        CurrentTermResolver.parseCurrentTermFromIndexHtml(badYear),
        isNull,
      );
      expect(
        CurrentTermResolver.parseCurrentTermFromIndexHtml(badTerm),
        isNull,
      );
    });
  });

  group('CurrentTermResolver cache', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await CurrentTermResolver.instance.debugReset();
    });

    test(
      'resolve returns null without login instead of hitting network',
      () async {
        final context = await CurrentTermResolver.instance.resolve();
        expect(context, isNull);
      },
    );
  });
}
