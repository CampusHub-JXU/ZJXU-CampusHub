import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';

import '../../helpers/property.dart';

void main() {
  const weekdaySymbols = ['一', '二', '三', '四', '五', '六', '日'];

  // 课程名/教师/教室字母表刻意排除了消息模板中的关键字，
  // 避免生成器制造出解析器本身无法处理的真实业务之外的歧义文本。
  const courseNameAlphabet = '高等数学线性代数据结构英语体育AI+创新创业与实践1A';
  const teacherAlphabet = '汤龙杨月红胡亚楠王张刘陈';
  const classroomAlphabet = '明德笃行楼教ABC012346789';

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

    test('不含提醒关键词的文本永远不产生规则', () {
      // 字母表中不含 提/醒/调/停/补，无法拼出任何提醒关键词。
      final noiseGen = stringsOf('今夜月色很好明日风和日丽大家记得早睡上课认真听讲', 0, 40);

      forAll('普通文本消息解析结果为空', noiseGen, (String noise) {
        expect(parseScheduleChangeMessages([noise]), isEmpty, reason: noise);
      });
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
