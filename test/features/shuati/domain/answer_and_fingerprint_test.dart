// 移植自 PWA tests/domain/answerJudge.test.ts 与 tests/domain/questionFingerprint.test.ts
// （describe/it 名称写在各 test 的说明里）。
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/answer_judge.dart';
import 'package:jxu_campus_hub/features/shuati/domain/js_compat.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_fingerprint.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';

Question q(List<String> answer, {QuestionType? type, String text = 'test'}) =>
    Question(
      id: 'q1',
      bankId: 'b1',
      type:
          type ??
          (answer.length > 1 ? QuestionType.multiple : QuestionType.single),
      question: text,
      answer: answer,
    );

Question fq({
  String text = '测试题目',
  Map<String, String>? options = const {'A': '选项A', 'B': '选项B'},
  List<String> answer = const ['A'],
  String id = 'q1',
}) => Question(
  id: id,
  bankId: 'b1',
  type: QuestionType.single,
  question: text,
  options: options,
  answer: answer,
);

void main() {
  group('checkAnswer (answerJudge.test.ts)', () {
    // describe('单选题')
    test('正确答案 → correct', () {
      expect(checkAnswer(q(['A']), ['A']), AnswerStatus.correct);
    });
    test('错误答案 → wrong', () {
      expect(checkAnswer(q(['A']), ['B']), AnswerStatus.wrong);
    });
    test('大小写不敏感', () {
      expect(checkAnswer(q(['A']), ['a']), AnswerStatus.correct);
      expect(checkAnswer(q(['a']), ['A']), AnswerStatus.correct);
    });
    test('多选题顺序无关', () {
      expect(checkAnswer(q(['A', 'C']), ['C', 'A']), AnswerStatus.correct);
      expect(checkAnswer(q(['C', 'A']), ['A', 'C']), AnswerStatus.correct);
    });

    // describe('多选题')
    test('完全匹配 → correct', () {
      expect(
        checkAnswer(q(['A', 'B', 'C']), ['A', 'B', 'C']),
        AnswerStatus.correct,
      );
    });
    test('遗漏选项 → wrong', () {
      expect(checkAnswer(q(['A', 'C']), ['A']), AnswerStatus.wrong);
    });
    test('多选选项 → wrong', () {
      expect(checkAnswer(q(['A']), ['A', 'B']), AnswerStatus.wrong);
    });
    test('大小写混合', () {
      expect(checkAnswer(q(['A', 'C']), ['c', 'a']), AnswerStatus.correct);
    });

    // describe('判断题')
    test('true / false 正确，true vs false → wrong', () {
      expect(
        checkAnswer(q(['true'], type: QuestionType.judge), ['true']),
        AnswerStatus.correct,
      );
      expect(
        checkAnswer(q(['false'], type: QuestionType.judge), ['false']),
        AnswerStatus.correct,
      );
      expect(
        checkAnswer(q(['true'], type: QuestionType.judge), ['false']),
        AnswerStatus.wrong,
      );
    });

    // describe('边界情况')
    test('空答案 → unanswered', () {
      expect(checkAnswer(q(['A']), []), AnswerStatus.unanswered);
    });
    test('null 答案 → unanswered', () {
      expect(checkAnswer(q(['A']), null), AnswerStatus.unanswered);
    });
    test('题库答案缺失时不会抛错', () {
      expect(checkAnswer(q(const []), ['A']), AnswerStatus.wrong);
    });
    test('自动忽略空白答案项', () {
      expect(checkAnswer(q([' A ', '']), ['a', ' ']), AnswerStatus.correct);
    });
    test('填空题正确 / 大小写不敏感', () {
      expect(
        checkAnswer(q(['hello'], type: QuestionType.blank), ['hello']),
        AnswerStatus.correct,
      );
      expect(
        checkAnswer(q(['Hello'], type: QuestionType.blank), ['hello']),
        AnswerStatus.correct,
      );
    });
  });

  group('buildContentKey (questionFingerprint.test.ts)', () {
    test('包含题型、题目、选项', () {
      final key = buildContentKey(fq());
      expect(key, contains('single'));
      expect(key, contains('测试题目'));
      expect(key, contains('A:选项A'));
      expect(key, contains('B:选项B'));
    });
    test('空白字符规范化为单空格', () {
      final key = buildContentKey(fq(text: '测试   题目  内容'));
      expect(key, contains('测试 题目 内容'));
      expect(key, isNot(contains('   ')));
    });
    test('中文标点转英文标点', () {
      expect(
        buildContentKey(fq(text: '测试，题目。内容；标题：副标题')),
        contains('测试,题目.内容;标题:副标题'),
      );
    });
    test('选项按 key 字母排序', () {
      final key = buildContentKey(fq(options: {'C': '丙', 'A': '甲', 'B': '乙'}));
      expect(key.indexOf('A:甲'), lessThan(key.indexOf('B:乙')));
      expect(key.indexOf('B:乙'), lessThan(key.indexOf('C:丙')));
    });
    test('无选项时选项部分为空字符串', () {
      final key = buildContentKey(fq(options: null));
      expect(key, isNot(contains('A:')));
      expect(key, isNot(contains('B:')));
    });
    test('相同内容产生相同 key（与 id 无关）', () {
      expect(buildContentKey(fq(id: 'x1')), buildContentKey(fq(id: 'x2')));
    });
    test('不同题目产生不同 key', () {
      expect(
        buildContentKey(fq(text: '题A')),
        isNot(buildContentKey(fq(text: '题B'))),
      );
    });
  });

  group('buildAnswerKey', () {
    test('单答案 / 多答案排序 / 顺序无关 / 判断题', () {
      expect(buildAnswerKey(fq(answer: ['A'])), 'A');
      expect(buildAnswerKey(fq(answer: ['C', 'A', 'B'])), 'A,B,C');
      expect(
        buildAnswerKey(fq(answer: ['B', 'A'])),
        buildAnswerKey(fq(answer: ['A', 'B'])),
      );
      expect(buildAnswerKey(fq(answer: ['true'])), 'true');
    });
  });

  group('attachQuestionHashes', () {
    test('为每个题目附加 contentHash 和 answerHash，十六进制长度 64', () {
      final result = attachQuestionHashes([fq(), fq(id: 'q2', text: '另一题')]);
      expect(result, hasLength(2));
      for (final r in result) {
        expect(r.contentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(r.answerHash, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    });
    test('相同内容产生相同 hash；不同答案产生不同 answerHash', () {
      final same = attachQuestionHashes([fq(), fq(id: 'q2')]);
      expect(same[0].contentHash, same[1].contentHash);
      final diff = attachQuestionHashes([
        fq(answer: ['A']),
        fq(id: 'q2', answer: ['B']),
      ]);
      expect(diff[0].answerHash, isNot(diff[1].answerHash));
    });
    test('空数组返回空数组', () {
      expect(attachQuestionHashes([]), isEmpty);
    });

    // 黄金向量：由 PWA 原始 questionFingerprint.ts 在 Node 24 下计算（见 tools/shuati_golden）。
    test('SHA-256 黄金向量与 PWA 一致（保证重复导入跨端判重）', () {
      final h = attachQuestionHash(
        Question(
          id: '1',
          bankId: 'b',
          type: QuestionType.single,
          question: '测试题目',
          options: const {'A': '选项A', 'B': '选项B'},
          answer: const ['A'],
        ),
      );
      expect(
        h.contentHash,
        '0e8612b2cdea5c30ec8cb0bbf93f7cb5b8a6e6b5982b04a86d34adbce14301f5',
      );
      expect(
        h.answerHash,
        '559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd',
      );

      final mixed = attachQuestionHash(
        Question(
          id: '5',
          bankId: 'b',
          type: QuestionType.multiple,
          question: '多选',
          options: const {'a': '小写', 'B': '大写', 'true': 't', '1': 'one'},
          answer: const ['B', 'A', 'D'],
        ),
      );
      expect(
        mixed.contentHash,
        '7c525bf48dabdafc8a5d804f8a7ce00666d7790b023783a0200626f559bc9fd3',
      );
      expect(
        mixed.answerHash,
        'ae4cb965597dfce6441b7f5adabbda668a1110f10bb07af95c4d7d5825ed4f23',
      );
    });
  });

  group('js_compat（与浏览器 JS 语义对齐的小工具）', () {
    test('jsTrim 与 JS trim 同一字符集（不含 U+0085，含 BOM / 全角空格）', () {
      expect(jsTrim('﻿　 a   '), 'a');
      expect(jsTrim('\u0085a\u0085'), '\u0085a\u0085');
      expect(jsTrim(''), '');
    });

    test('正则 \\s 与 isJsWhitespace 一致（保证指纹规范化与 PWA 相同）', () {
      final re = RegExp(r'\s');
      for (var c = 0; c < 0x10000; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        expect(
          re.hasMatch(String.fromCharCode(c)),
          isJsWhitespace(c),
          reason: 'U+${c.toRadixString(16)}',
        );
      }
    });

    test('jsNumberToString：整数值不带 .0', () {
      expect(jsNumberToString(3.0), '3');
      expect(jsNumberToString(1.5), '1.5');
      expect(jsNumberToString(7), '7');
      expect(jsNumberToString(-0.0), '0');
    });

    test('jsLocaleCompare：数字 < 字母，忽略大小写主序，同字母小写在前', () {
      final keys = ['true', 'B', 'a', '1', 'Z', 'z', 'A', 'false'];
      keys.sort(jsLocaleCompare);
      expect(keys, ['1', 'a', 'A', 'B', 'false', 'true', 'z', 'Z']);
    });

    test('stableSorted 保持相等元素的原有顺序', () {
      final items = [(1, 'a'), (0, 'b'), (1, 'c'), (0, 'd')];
      final sorted = stableSorted<(int, String)>(
        items,
        (a, b) => a.$1.compareTo(b.$1),
      );
      expect(sorted.map((e) => e.$2), ['b', 'd', 'a', 'c']);
    });
  });
}
