// 移植自 PWA tests/domain/textParser.test.ts 与 tests/domain/wrongQuestion.test.ts，
// 外加 tests/services/wrongQuestionService.test.ts / wrongQuestionRepo.test.ts 的纯函数部分。
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_text_parser.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_type.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/domain/wrong_question.dart';

// tests/fixtures/import/option-explanations.txt
const optionExplanationsFixture = '''
1、以下哪个是离线优先 PWA 的核心能力？
A、所有数据只能存储在服务器
B、Service Worker 可以缓存资源以支持离线访问
C、必须每次打开都重新下载安装包
D、IndexedDB 只能保存字符串
答案：B
解析：离线优先应用通常结合 Service Worker 缓存静态资源，并用 IndexedDB 保存本地数据。
A解析：这与离线优先相反，离线优先应尽量减少对服务器的即时依赖。
B解析：这是正确项，Service Worker 可以拦截请求并返回缓存资源。
C解析：PWA 安装后不需要每次重新下载安装包。
D解析：IndexedDB 可以保存结构化数据，不只限于字符串。
''';

String lines(List<String> l) => l.join('\n');

void main() {
  group('parseTextToQuestions (textParser.test.ts)', () {
    group('标准格式', () {
      test('题号 + 题干 + 选项逐行 + 独立答案行', () {
        final result = parseTextToQuestions(
          lines([
            '1、以下哪个是正确的（ ）。',
            'A、 选项A',
            'B、 选项B',
            'C、 选项C',
            'D、 选项D',
            '答案：A',
          ]),
        );
        expect(result, hasLength(1));
        expect(result[0].question, contains('以下哪个是正确的'));
        expect(result[0].question, contains('____'));
        expect(result[0].options, {
          'A': '选项A',
          'B': '选项B',
          'C': '选项C',
          'D': '选项D',
        });
        expect(result[0].answer, ['A']);
      });
      test('第N题格式也识别', () {
        final result = parseTextToQuestions(
          lines(['第1题、题目内容', 'A、选项A', 'B、选项B', '答案：B']),
        );
        expect(result, hasLength(1));
        expect(result[0].answer, ['B']);
      });
    });

    group('行内格式 / Tab / 行内选项', () {
      test('题干 + 答案在同一行（选项被合并进答案）', () {
        final result = parseTextToQuestions(
          '1、以下哪个是正确的 答案：A A、选项A B、选项B C、选项C D、选项D',
        );
        expect(result, hasLength(1));
        expect(result[0].answer.length, greaterThanOrEqualTo(1));
      });
      test('题干和答案用 tab 分隔', () {
        final result = parseTextToQuestions('1、题目内容\t答案：B\nA、选项A\nB、选项B');
        expect(result, hasLength(1));
        expect(result[0].answer, ['B']);
      });
      test('选项写在同一行', () {
        final result = parseTextToQuestions('1、题目内容 A、选项A B、选项B C、选项C 答案：C');
        expect(result, hasLength(1));
        expect(result[0].answer, ['C']);
        expect(result[0].options, isNotNull);
      });
    });

    group('解析提取', () {
      test('提取独立行的解析', () {
        final result = parseTextToQuestions(
          lines(['1、题目内容', 'A、选项A', 'B、选项B', '答案：A', '解析：因为A是对的']),
        );
        expect(result[0].explanation, '因为A是对的');
      });
      test('解析写在同一行', () {
        final result = parseTextToQuestions('1、题目内容 解析：这是解析 答案：A A、选项A B、选项B');
        expect(result, hasLength(1));
        expect(result[0].explanation, contains('这是解析'));
      });
      test('从 fixture 提取每个选项的解析', () {
        final result = parseTextToQuestions(optionExplanationsFixture);
        expect(result, hasLength(1));
        expect(result[0].explanation, contains('离线优先应用'));
        expect(result[0].optionExplanations, {
          'A': '这与离线优先相反，离线优先应尽量减少对服务器的即时依赖。',
          'B': '这是正确项，Service Worker 可以拦截请求并返回缓存资源。',
          'C': 'PWA 安装后不需要每次重新下载安装包。',
          'D': 'IndexedDB 可以保存结构化数据，不只限于字符串。',
        });
      });
    });

    group('判断题', () {
      const judgeAnswers = {
        '对': 'true',
        '正确': 'true',
        '√': 'true',
        'True': 'true',
        'T': 'true',
        '是': 'true',
        '错': 'false',
        '错误': 'false',
        '不正确': 'false',
        '×': 'false',
        'False': 'false',
        'F': 'false',
        '否': 'false',
      };
      for (final entry in judgeAnswers.entries) {
        test('答案为「${entry.key}」→ ${entry.value}', () {
          final result = parseTextToQuestions('1、这是一道判断题\n答案：${entry.key}');
          expect(result, hasLength(1));
          expect(result[0].answer, [entry.value]);
        });
      }
    });

    group('多选题', () {
      Map<String, List<String>> multi() => {
        'AC': ['A', 'C'],
        'A,C': ['A', 'C'],
        'A C': ['A', 'C'],
        'A、C': ['A', 'C'],
        'ABC': ['A', 'B', 'C'],
      };
      for (final entry in multi().entries) {
        test('答案 ${entry.key}', () {
          final result = parseTextToQuestions(
            lines(['1、题目内容', 'A、甲', 'B、乙', 'C、丙', '答案：${entry.key}']),
          );
          expect(result, hasLength(1));
          expect(result[0].answer, entry.value);
        });
      }
    });

    group('答案格式变体', () {
      for (final label in ['答案：A', '正确答案：A', 'answer: A', '答：A']) {
        test(label, () {
          final text = lines(['1、题目内容', 'A、选项A', 'B、选项B', label]);
          expect(parseTextToQuestions(text)[0].answer, ['A']);
        });
      }
    });

    test('跳过只有标号的章节标题行', () {
      final result = parseTextToQuestions(
        lines([
          '一、',
          '1、以下哪个是正确的',
          'A、选项A',
          '答案：A',
          '二、',
          '2、这是一道判断题目',
          '答案：对',
        ]),
      );
      expect(result, hasLength(2));
      expect(result[0].answer, ['A']);
      expect(result[1].answer, ['true']);
    });

    test('空字符串 / 只有空白返回空数组', () {
      expect(parseTextToQuestions(''), isEmpty);
      expect(parseTextToQuestions('   \n\n   '), isEmpty);
    });

    group('边界情况', () {
      test('题干太短（< 4字符）被过滤', () {
        expect(parseTextToQuestions('1、AB\n答案：A'), isEmpty);
      });
      test('缺少答案的题目被过滤', () {
        expect(
          parseTextToQuestions(lines(['1、这是一道没有答案的题目', 'A、选项A', 'B、选项B'])),
          isEmpty,
        );
      });
      test('多题连续解析', () {
        final result = parseTextToQuestions(
          lines([
            '1、第一道题目内容',
            'A、选项A',
            '答案：A',
            '2、第二道题目内容',
            'B、选项B',
            '答案：B',
            '3、第三道题目内容',
            '答案：对',
          ]),
        );
        expect(result, hasLength(3));
        expect(result.map((q) => q.answer), [
          ['A'],
          ['B'],
          ['true'],
        ]);
      });
      test('括号规范化为 ____', () {
        final result = parseTextToQuestions(
          lines(['1、以下正确的是（ ）', 'A、选项A', '答案：A']),
        );
        expect(result[0].question, contains('____'));
      });
      test('HTML 实体解码', () {
        final result = parseTextToQuestions(
          lines(['1、什么是 &amp; 符号', 'A、选项A', '答案：A']),
        );
        expect(result[0].question, contains('&'));
        expect(result[0].question, isNot(contains('&amp;')));
      });
    });
  });

  group('inferQuestionType (textParser.test.ts)', () {
    test('判断题', () {
      expect(inferQuestionType(['true']), QuestionType.judge);
      expect(inferQuestionType(['false']), QuestionType.judge);
      expect(
        inferParsedQuestionType(
          const ParsedQuestion(question: '这是对的吗', answer: ['true']),
        ),
        QuestionType.judge,
      );
    });
    test('单选 / 多选', () {
      expect(
        inferQuestionType(['A'], options: {'A': '甲', 'B': '乙'}),
        QuestionType.single,
      );
      expect(
        inferQuestionType(['A', 'C'], options: {'A': '甲', 'B': '乙', 'C': '丙'}),
        QuestionType.multiple,
      );
    });
    test('填空：____ / （  ） / （）', () {
      expect(
        inferQuestionType(['hello'], question: '填入____'),
        QuestionType.blank,
      );
      expect(
        inferQuestionType(['hello'], question: '填入（  ）'),
        QuestionType.blank,
      );
      expect(
        inferQuestionType(['hello'], question: '填入（）'),
        QuestionType.blank,
      );
    });
    test('简答：无选项 + 无空格标记', () {
      expect(
        inferQuestionType(['some text'], question: '简述一下这个概念'),
        QuestionType.short,
      );
    });
    test('ParsedQuestion 重载', () {
      expect(
        inferParsedQuestionType(
          const ParsedQuestion(
            question: '选择题',
            answer: ['A'],
            options: {'A': '甲', 'B': '乙'},
          ),
        ),
        QuestionType.single,
      );
      expect(
        inferParsedQuestionType(
          const ParsedQuestion(question: '请填入____内容', answer: ['hello']),
        ),
        QuestionType.blank,
      );
    });
  });

  group('旧别名不被识别（与 PWA isQuestionType 一致，落入题型推断）', () {
    test('fill / text / 大写 SINGLE 都不是合法 type', () {
      expect(QuestionType.tryParse('fill'), isNull);
      expect(QuestionType.tryParse('text'), isNull);
      expect(QuestionType.tryParse('SINGLE'), isNull);
      expect(QuestionType.tryParse(null), isNull);
      for (final t in QuestionType.values) {
        expect(QuestionType.tryParse(t.name), t);
      }
    });
  });

  group('getCurrentWrongQuestionIds (wrongQuestion.test.ts)', () {
    PracticeRecord rec(String q, AnswerStatus s, int ts, [int? id]) =>
        PracticeRecord(
          id: id,
          bankId: 'b1',
          questionId: q,
          userAnswer: const ['A'],
          status: s,
          timestamp: ts,
        );

    test('无记录 → 空数组', () => expect(getCurrentWrongQuestionIds([]), isEmpty));
    test('最新一次做对 → 不在错题本', () {
      expect(
        getCurrentWrongQuestionIds([
          rec('q1', AnswerStatus.wrong, 1),
          rec('q1', AnswerStatus.correct, 2),
        ]),
        isEmpty,
      );
    });
    test('最新一次做错 → 在错题本', () {
      expect(
        getCurrentWrongQuestionIds([
          rec('q1', AnswerStatus.correct, 1),
          rec('q1', AnswerStatus.wrong, 2),
        ]),
        ['q1'],
      );
    });
    test('只做错/做对一次', () {
      expect(getCurrentWrongQuestionIds([rec('q1', AnswerStatus.wrong, 1)]), [
        'q1',
      ]);
      expect(
        getCurrentWrongQuestionIds([rec('q1', AnswerStatus.correct, 1)]),
        isEmpty,
      );
    });
    test('多题混合', () {
      final r = getCurrentWrongQuestionIds([
        rec('q1', AnswerStatus.wrong, 1),
        rec('q1', AnswerStatus.correct, 2),
        rec('q2', AnswerStatus.correct, 1),
        rec('q2', AnswerStatus.wrong, 2),
        rec('q3', AnswerStatus.wrong, 1),
      ]);
      expect(r, containsAll(['q2', 'q3']));
      expect(r, isNot(contains('q1')));
    });
    test('unanswered 记录不影响结果', () {
      expect(
        getCurrentWrongQuestionIds([
          rec('q1', AnswerStatus.correct, 1),
          rec('q1', AnswerStatus.unanswered, 2),
        ]),
        isEmpty,
      );
    });
    test('按 timestamp 排序，相同 timestamp 按 id 排序', () {
      expect(
        getCurrentWrongQuestionIds([
          rec('q1', AnswerStatus.correct, 100, 2),
          rec('q1', AnswerStatus.wrong, 100, 1),
        ]),
        isEmpty,
      );
    });
    test('大量记录性能', () {
      final records = [
        for (var i = 0; i < 1000; i++)
          rec('q$i', i.isEven ? AnswerStatus.correct : AnswerStatus.wrong, i),
      ];
      expect(getCurrentWrongQuestionIds(records), hasLength(500));
    });
  });

  group('永久错题本规则 (wrongQuestionRepo / practiceAnswerService)', () {
    test('markWrong 新建：wrongCount=1，首次=最近', () {
      final w = markWrong(bankId: 'b1', questionId: 'q1', timestamp: 100);
      expect((w.firstWrongAt, w.lastWrongAt, w.wrongCount), (100, 100, 1));
    });

    test('markWrong 已有：不重复新建，lastWrongAt/次数/lastRecordId 更新', () {
      final first = markWrong(
        bankId: 'b1',
        questionId: 'q1',
        timestamp: 100,
        lastRecordId: 1,
      );
      final second = markWrong(
        bankId: 'b1',
        questionId: 'q1',
        timestamp: 200,
        existing: first,
        lastRecordId: 2,
      );
      expect(second.firstWrongAt, 100);
      expect(second.lastWrongAt, 200);
      expect(second.wrongCount, 2);
      expect(second.lastRecordId, 2);
    });

    test('markWrong 已有行次数异常（0/负）按 1 起算', () {
      const broken = PermanentWrongQuestion(
        bankId: 'b',
        questionId: 'q',
        firstWrongAt: 1,
        lastWrongAt: 1,
        wrongCount: 0,
      );
      expect(
        markWrong(
          bankId: 'b',
          questionId: 'q',
          timestamp: 2,
          existing: broken,
        ).wrongCount,
        2,
      );
    });

    test('sortWrongQuestionEntries：最近答错在前，同时间 id 大者在前', () {
      PermanentWrongQuestion e(String q, int last, int id) =>
          PermanentWrongQuestion(
            id: id,
            bankId: 'b',
            questionId: q,
            firstWrongAt: 1,
            lastWrongAt: last,
            wrongCount: 1,
          );
      final sorted = sortWrongQuestionEntries([
        e('old', 100, 1),
        e('tie-a', 200, 2),
        e('tie-b', 200, 3),
      ]);
      expect(sorted.map((x) => x.questionId), ['tie-b', 'tie-a', 'old']);
    });

    test('matchesWrongQuery：题干 / 选项 / 答案 / 标签，忽略大小写与空白折叠', () {
      const q = Question(
        id: 'q1',
        bankId: 'b1',
        type: QuestionType.single,
        question: 'React   state',
        options: {'A': 'useState', 'B': 'props'},
        answer: ['A'],
        tags: ['hooks'],
      );
      expect(matchesWrongQuery(q, 'hooks'), isTrue);
      expect(matchesWrongQuery(q, 'USESTATE'), isTrue);
      expect(matchesWrongQuery(q, 'react state'), isTrue);
      expect(matchesWrongQuery(q, 'A'), isTrue);
      expect(matchesWrongQuery(q, 'missing'), isFalse);
      expect(matchesWrongQuery(q, '   '), isTrue);
    });
  });
}
