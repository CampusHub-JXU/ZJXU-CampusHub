import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';

import '../../helpers/property.dart';

void main() {
  const weekdaySymbols = ['一', '二', '三', '四', '五', '六', '日'];

  // 课程名/教师/教室字母表刻意排除了消息模板中的关键字，
  // 避免生成器制造出解析器本身无法处理的真实业务之外的歧义文本。
  const courseNameAlphabet = '高等数学线性代数据结构英语体育AI+创新创业与实践1A';
  const teacherAlphabet = '汤龙杨月红胡亚楠王张刘陈';
  const classroomAlphabet = '明德笃行楼教ABC012346789';

  const mixedAreaThreeHtmlFixture = '''
<a class="list-group-item" data-tkxx="换教室提醒:原定李恒老师在第2-5周,7-18周星期一第6-7节兴德楼南楼223上的数字经济概论课程现改为在博学楼(8号楼)501上课，请各位同学相互告知！">
  <span class="fraction">2026-09-01 11:05:07</span>
</a>
<a class="list-group-item" data-tkxx="调课提醒:解丽老师于第12周星期四第8-9节在兴德楼南楼226上的大学英语(英语国家社会与文化)课程调课到由解丽老师在第13周星期四第8-9节兴德楼南楼226上课，请各位同学相互告知！">
  <span class="fraction">2026-05-19 14:46:48</span>
</a>
<a class="list-group-item" data-tkxx="调课提醒:沈芳老师于第10周星期三第3-4节在兴德楼南楼107上的大学生职业规划与就业指导1课程调课到由沈芳老师在第10周星期三第3-4节网络平台上课，请各位同学相互告知！">
  <span class="fraction">2026-04-29 09:33:22</span>
</a>
<a class="list-group-item" data-tkxx="调课提醒:刘晓罡老师于第8周星期五第8-10节在厚德楼308上的微观经济学课程调课到由刘晓罡老师在第8周星期二第8-10节厚德楼255上课，请各位同学相互告知！">
  <span class="fraction">2026-04-20 09:35:44</span>
</a>
<a class="list-group-item" data-tkxx="调课提醒:胡亚楠老师于第8周星期一第1-2节在铭德楼467上的AI+创新创业基础课程调课到由胡亚楠老师在第8周星期四第1-2节厚德楼259上课，请各位同学相互告知！">
  <span class="fraction">2026-04-20 08:30:46</span>
</a>
''';

  final slotGen = Gen<(int, int, int, int)>((random) {
    final week = intsInRange(1, 25).next(random);
    final weekday = intsInRange(1, 7).next(random);
    final startLesson = intsInRange(1, 12).next(random);
    final endLesson = intsInRange(startLesson, 12).next(random);
    return (week, weekday, startLesson, endLesson);
  });

  final textGen = Gen<(String, String, String)>((random) {
    return (
      stringsOf(courseNameAlphabet, 2, 8).next(random),
      stringsOf(teacherAlphabet, 2, 3).next(random),
      stringsOf(classroomAlphabet, 3, 6).next(random),
    );
  });

  final singleLessonGen = booleans();

  /// (节次, 课程名/教师/教室, 是否只写单节) 的随机组合。
  final cancelCaseGen =
      Gen<((int, int, int, int), (String, String, String), bool)>((random) {
        return (
          slotGen.next(random),
          textGen.next(random),
          singleLessonGen.next(random),
        );
      });

  String lessonText((int, int, int, int) slot, bool singleLesson) {
    final (week, weekday, startLesson, endLesson) = slot;
    final range = singleLesson ? '$startLesson' : '$startLesson-$endLesson';
    return '第$week周星期${weekdaySymbols[weekday - 1]}第$range节';
  }

  group('调课提醒消息解析 round-trip', () {
    test('停课提醒：消息中的节次信息被完整还原', () {
      forAll('随机节次组装停课消息后应还原出 cancel 规则', cancelCaseGen, (values) {
        final (slot, meta, single) = values;
        final (courseName, teacher, classroom) = meta;
        final message =
            '停课提醒:原定$teacher老师${lessonText(slot, single)}于$classroom'
            '上的$courseName课程停课，请各位同学相互告知！';

        final rules = parseScheduleChangeMessages([message]);

        expect(rules, hasLength(1), reason: message);
        final rule = rules.single;
        expect(rule.type, CourseChangeType.cancel);
        // 单节消息只写"第N节"，结束节次默认等于开始节次。
        final expectedEndLesson = single ? slot.$3 : slot.$4;
        expect(
          rule.originalLesson?.signature,
          '${slot.$1}-${slot.$2}-${slot.$3}-$expectedEndLesson',
          reason: message,
        );
        expect(rule.targetLesson, isNull);
        expect(rule.courseName, courseName);
        // 停课路径刻意不提取老师名（删除课表不需要教师信息）。
        expect(rule.teacherName, isNull, reason: message);
      });
    });

    test('补课提醒：目标节次被完整还原', () {
      forAll('随机节次组装补课消息后应还原出 makeup 规则', cancelCaseGen, (values) {
        final (slot, meta, single) = values;
        final (courseName, teacher, _) = meta;
        final message =
            '补课提醒:$teacher老师将在${lessonText(slot, single)}对课程$courseName'
            '进行补课，请各位同学相互告知！';

        final rules = parseScheduleChangeMessages([message]);

        expect(rules, hasLength(1), reason: message);
        final rule = rules.single;
        expect(rule.type, CourseChangeType.makeup);
        // 单节消息只写"第N节"，结束节次默认等于开始节次。
        final expectedEndLesson = single ? slot.$3 : slot.$4;
        expect(
          rule.targetLesson?.signature,
          '${slot.$1}-${slot.$2}-${slot.$3}-$expectedEndLesson',
          reason: message,
        );
        expect(rule.originalLesson, isNull);
        expect(rule.courseName, courseName);
        expect(rule.teacherName, teacher);
      });
    });

    test('调课提醒：原节次与新节次同时被还原', () {
      final twoSlotGen = Gen<((int, int, int, int), (int, int, int, int))>((
        random,
      ) {
        return (slotGen.next(random), slotGen.next(random));
      });

      forAll('随机原/新节次组装调课消息后应还原出 reschedule 规则', pair(twoSlotGen, textGen), (
        values,
      ) {
        final (slots, meta) = values;
        final (original, target) = slots;
        final (courseName, teacher, classroom) = meta;
        final message =
            '调课提醒:$teacher老师于${lessonText(original, false)}在$classroom'
            '上的$courseName课程调课到由$teacher老师${lessonText(target, false)}'
            '在$classroom上的$courseName课程，请各位同学相互告知！';

        final rules = parseScheduleChangeMessages([message]);

        expect(rules, hasLength(1), reason: message);
        final rule = rules.single;
        expect(rule.type, CourseChangeType.reschedule);
        expect(
          rule.originalLesson?.signature,
          '${original.$1}-${original.$2}-${original.$3}-${original.$4}',
          reason: message,
        );
        expect(
          rule.targetLesson?.signature,
          '${target.$1}-${target.$2}-${target.$3}-${target.$4}',
          reason: message,
        );
        expect(rule.courseName, courseName);
        expect(rule.classroom, classroom);
      });
    });

    test('重复消息被去重，重复次数不影响规则数量', () {
      final duplicateGen = Gen<List<String>>((random) {
        final slot = slotGen.next(random);
        final (courseName, teacher, classroom) = textGen.next(random);
        final message =
            '停课提醒:原定$teacher老师${lessonText(slot, false)}于$classroom'
            '上的$courseName课程停课，请各位同学相互告知！';
        final copies = intsInRange(1, 6).next(random);
        return List.filled(copies, message);
      });

      forAll('同一消息重复 N 次只产生一条规则', duplicateGen, (List<String> messages) {
        final rules = parseScheduleChangeMessages(messages);
        expect(rules, hasLength(1));
      });
    });

    test('跨来源去重时保留带发布时间的副本', () {
      const message =
          '换教室提醒:原定李恒老师在第2周星期一第6-7节兴德楼南楼223上的数字经济概论课程现改为在博学楼(8号楼)501上课，请各位同学相互告知！';
      final rules = parseScheduleChangeMessageEntries([
        const ScheduleChangeMessage(message: message),
        ScheduleChangeMessage(
          message: message,
          publishedAt: DateTime(2026, 9, 1, 11, 5, 7),
        ),
      ]);

      expect(rules, hasLength(1));
      expect(rules.single.publishedAt, DateTime(2026, 9, 1, 11, 5, 7));
    });

    test('不含提醒关键词的文本永远不产生规则', () {
      // 字母表中不含 提/醒/调/停/补，无法拼出任何提醒关键词。
      final noiseGen = stringsOf('今夜月色很好明日风和日丽大家记得早睡上课认真听讲', 0, 40);

      forAll('普通文本消息解析结果为空', noiseGen, (String noise) {
        expect(parseScheduleChangeMessages([noise]), isEmpty, reason: noise);
      });
    });
  });

  group('真实 AreaThree 消息形状', () {
    test('解析换教室周次范围，并不把发布日期当作学期证据', () {
      final entries = extractScheduleChangeMessageEntriesFromAreaThreeHtml(
        mixedAreaThreeHtmlFixture,
      );
      final messages = extractScheduleChangeMessagesFromAreaThreeHtml(
        mixedAreaThreeHtmlFixture,
      );
      final rules = parseScheduleChangeMessageEntries(entries);

      expect(messages, hasLength(5));
      expect(entries, hasLength(5));
      expect(entries.first.publishedAt, DateTime(2026, 9, 1, 11, 5, 7));
      expect(entries[1].publishedAt, DateTime(2026, 5, 19, 14, 46, 48));
      expect(rules.where((rule) => rule.courseName == '数字经济概论'), hasLength(16));
      expect(
        rules
            .where((rule) => rule.courseName == '数字经济概论')
            .every(
              (rule) =>
                  rule.originalLesson?.signature ==
                      rule.targetLesson?.signature &&
                  rule.classroom == '博学楼(8号楼)501' &&
                  rule.termContext == null,
            ),
        isTrue,
      );
      final roomChange = rules
          .where((rule) => rule.courseName == '数字经济概论')
          .first;
      expect(roomChange.rawMessage, contains('数字经济概论'));
      expect(roomChange.originalClassroom, '兴德楼南楼223');
      expect(roomChange.classroom, '博学楼(8号楼)501');
      expect(roomChange.publishedAt, DateTime(2026, 9, 1, 11, 5, 7));

      const current = ScheduleTermContext(academicYear: 2026, term: 3);
      expect(filterScheduleChangeRulesForTerm(rules, current), isEmpty);

      final explicit = parseScheduleChangeMessages([
        '2026-2027学年第1学期 调课提醒:胡亚楠老师于第8周星期一第1-2节在铭德楼467上的AI+创新创业基础课程调课到由胡亚楠老师在第8周星期四第1-2节厚德楼259上课，请各位同学相互告知！',
      ]).single;
      expect(explicit.termContext, current);
      expect(filterScheduleChangeRulesForTerm([explicit, ...rules], current), [
        explicit,
      ]);
    });

    test('非法日期降级为未知，未来日期保留', () {
      expect(parseScheduleChangePublishedAt('2026-02-30 09:00:00'), isNull);
      expect(parseScheduleChangePublishedAt('not-a-date'), isNull);
      expect(
        parseScheduleChangePublishedAt('2099-01-01 00:00:00'),
        DateTime(2099, 1, 1),
      );
    });

    test('畸形学年范围降级为未知', () {
      final rule = parseScheduleChangeMessages([
        '2026-2028学年第1学期 换教室提醒:原定李老师在第2周星期一第1节A楼101上的高等数学课程现改为在B楼202上课，请各位同学相互告知！',
      ]).single;

      expect(rule.termContext, isNull);
    });
  });

  group('normalizeCourseName 归一化不变量', () {
    test('归一化是幂等的：normalize(normalize(x)) == normalize(x)', () {
      const noisyAlphabet = 'AbA大物1 　（）()【】-—_、，,。.：:；;《》<>/+*高数英语体育';
      forAll('任意字符串二次归一化结果不变', stringsOf(noisyAlphabet, 0, 30), (String value) {
        final once = normalizeCourseName(value);
        expect(normalizeCourseName(once), once);
      });
    });

    test('归一化结果不再包含任何待剔除字符', () {
      const strippedChars = {
        ' ',
        '　',
        '（',
        '）',
        '(',
        ')',
        '【',
        '】',
        '[',
        ']',
        '<',
        '>',
        '《',
        '》',
        '，',
        ',',
        '。',
        '.',
        '：',
        ':',
        '；',
        ';',
        '、',
        '/',
        '+',
        '-',
        '—',
        '_',
      };
      const noisyAlphabet = 'AbA大物1 　（）()【】-—_、，,。.：:；;《》<>/+*高数英语体育';
      forAll('输出中不出现任何标点或分隔符', stringsOf(noisyAlphabet, 0, 30), (String value) {
        final normalized = normalizeCourseName(value);
        for (final char in normalized.split('')) {
          expect(strippedChars.contains(char), isFalse, reason: normalized);
        }
      });
    });
  });
}
