// 刷题助手 AI 服务（Issue #117）：解析生成 + 缓存、缺答案补全、追问上下文。
// runner 用 fake，不触网络；持久化走内存 SQLite。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/ai/shuati_ai_models.dart';
import 'package:jxu_campus_hub/features/shuati/ai/shuati_ai_service.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';

import '../../../helpers/shuati_test_support.dart';

/// 依次返回排队响应；耗尽且未给 handler 时抛错。
class FakeRunner implements ShuatiAiLlmRunner {
  FakeRunner([List<String>? texts]) : _texts = [...?texts];

  final List<String> _texts;
  final List<ShuatiAiRequest> requests = [];
  Object? error;
  String model = 'fake-model';

  @override
  Future<ShuatiAiCompletion> complete(ShuatiAiRequest request) async {
    requests.add(request);
    if (error != null) throw error!;
    if (_texts.isEmpty) {
      throw StateError('FakeRunner: no queued response');
    }
    return ShuatiAiCompletion(text: _texts.removeAt(0), model: model);
  }
}

Future<(ShuatiStore, ShuatiAiService, FakeRunner)> setup({
  List<String>? responses,
}) async {
  final store = await openTestStore();
  final runner = FakeRunner(responses);
  var tick = 1700000000000;
  final service = ShuatiAiService(
    store.aiExplanations,
    runner,
    clock: () => DateTime.fromMillisecondsSinceEpoch(tick++),
  );
  return (store, service, runner);
}

Question choice(
  String id, {
  String bankId = 'b1',
  List<String> answer = const ['B'],
}) => Question(
  id: id,
  bankId: bankId,
  type: QuestionType.single,
  question: '2+2 等于几？',
  options: const {'A': '3', 'B': '4'},
  answer: answer,
);

Future<Question> seedQuestion(ShuatiStore store, Question q) async {
  await seedBank(store, q.bankId, [q]);
  return q;
}

void main() {
  group('getOrGenerateExplanation', () {
    test('生成 → 解析 JSON → 写缓存；第二次命中缓存不再调用 LLM', () async {
      final (store, service, runner) = await setup(
        responses: [
          '{"explanation": "因为四则运算。", "optionExplanations": {"A": "3 不对", "B": "正确"}}',
        ],
      );
      final q = await seedQuestion(store, choice('q1'));

      final first = await service.getOrGenerateExplanation(question: q);
      expect(first.fromCache, isFalse);
      expect(first.explanation, '因为四则运算。');
      expect(first.optionExplanations, {'A': '3 不对', 'B': '正确'});
      expect(first.model, 'fake-model');
      expect(runner.requests, hasLength(1));
      expect(runner.requests.single.prompt, contains('2+2 等于几'));

      final cached = await store.aiExplanations.getCached('q1');
      expect(cached, isNotNull);
      expect(cached!.bankId, 'b1');
      expect(cached.model, 'fake-model');
      expect(cached.createdAt, 1700000000000);

      final second = await service.getOrGenerateExplanation(question: q);
      expect(second.fromCache, isTrue);
      expect(second.explanation, '因为四则运算。');
      expect(second.optionExplanations, {'A': '3 不对', 'B': '正确'});
      expect(runner.requests, hasLength(1));
    });

    test('缓存是纯文本（PWA 旧行）时原样返回', () async {
      final (store, service, runner) = await setup();
      final q = await seedQuestion(store, choice('q1'));
      await store.aiExplanations.insertRaw(
        AiExplanationRow(
          bankId: 'b1',
          questionId: q.id,
          explanation: '旧的纯文本解析',
          model: 'old-model',
          createdAt: 1,
        ),
      );
      final result = await service.getOrGenerateExplanation(question: q);
      expect(result.fromCache, isTrue);
      expect(result.explanation, '旧的纯文本解析');
      expect(result.optionExplanations, isNull);
      expect(runner.requests, isEmpty);
    });

    test('forceRefresh 忽略缓存重新生成，同一题只留最新一行', () async {
      final (store, service, runner) = await setup(
        responses: ['{"explanation": "v1"}', '{"explanation": "v2"}'],
      );
      final q = await seedQuestion(store, choice('q1'));
      await service.getOrGenerateExplanation(question: q);
      final refreshed = await service.getOrGenerateExplanation(
        question: q,
        forceRefresh: true,
      );
      expect(refreshed.explanation, 'v2');
      expect(runner.requests, hasLength(2));
      final all = await store.aiExplanations.getAll();
      expect(all, hasLength(1));
      expect(all.single.explanation, contains('v2'));
      // 再次读取命中的是新生成的一行
      final third = await service.getOrGenerateExplanation(question: q);
      expect(third.explanation, 'v2');
      expect(third.fromCache, isTrue);
      expect(runner.requests, hasLength(2));
    });

    test('getCached 取最新行；upsertForQuestion 直接替换旧行', () async {
      final (store, service, runner) = await setup();
      final q = await seedQuestion(store, choice('q1'));
      // 模拟历史遗留：同一题两行旧缓存，应读 id 大者
      await store.aiExplanations.insertRaw(
        AiExplanationRow(
          bankId: 'b1',
          questionId: q.id,
          explanation: 'old',
          createdAt: 1,
        ),
      );
      await store.aiExplanations.insertRaw(
        AiExplanationRow(
          bankId: 'b1',
          questionId: q.id,
          explanation: 'new',
          createdAt: 2,
        ),
      );
      expect((await store.aiExplanations.getCached('q1'))!.explanation, 'new');
      final cached = await service.getOrGenerateExplanation(question: q);
      expect(cached.explanation, 'new');
      expect(runner.requests, isEmpty);

      await store.aiExplanations.upsertForQuestion(
        AiExplanationRow(
          bankId: 'b1',
          questionId: q.id,
          explanation: 'newest',
          createdAt: 3,
        ),
      );
      expect(await store.aiExplanations.getAll(), hasLength(1));
      expect(
        (await store.aiExplanations.getCached('q1'))!.explanation,
        'newest',
      );
    });

    test('非 JSON 响应降级为整段文本解析', () async {
      final (store, service, runner) = await setup(
        responses: ['这题选 B，因为 2+2=4。'],
      );
      final q = await seedQuestion(store, choice('q1'));
      final result = await service.getOrGenerateExplanation(question: q);
      expect(result.explanation, '这题选 B，因为 2+2=4。');
      expect(result.optionExplanations, isNull);
      // 降级文本也会写缓存
      expect(await store.aiExplanations.getCached('q1'), isNotNull);
      expect(runner.requests, hasLength(1));
    });

    test('带 markdown 围栏的 JSON 也能解析', () async {
      final (store, service, runner) = await setup(
        responses: ['```json\n{"explanation": "围栏里的解析"}\n```'],
      );
      final q = await seedQuestion(store, choice('q1'));
      final result = await service.getOrGenerateExplanation(question: q);
      expect(result.explanation, '围栏里的解析');
      expect(runner.requests, hasLength(1));
    });

    test('runner 抛错 → ShuatiAiFailure；空响应 → ShuatiAiFailure', () async {
      final (store, service, runner) = await setup();
      final q = await seedQuestion(store, choice('q1'));
      runner.error = Exception('connection refused');
      await expectLater(
        service.getOrGenerateExplanation(question: q),
        throwsA(isA<ShuatiAiFailure>()),
      );
      runner.error = null;
      runner.model = 'm';
      // 空文本响应
      final (store2, service2, _) = await setup(responses: ['   ']);
      final q2 = await seedQuestion(store2, choice('q2', bankId: 'b2'));
      await expectLater(
        service2.getOrGenerateExplanation(question: q2),
        throwsA(isA<ShuatiAiFailure>()),
      );
      // 失败不写缓存
      expect(await store.aiExplanations.getCached('q1'), isNull);
    });
  });

  group('enrichMissingAnswers', () {
    test('只补缺答案的题，按原下标返回补丁；已有答案的题不出现在提示词里', () async {
      final (store, service, runner) = await setup(
        responses: [
          jsonEncode([
            {'answer': 'B', 'explanation': '选 B 因为'},
          ]),
        ],
      );
      await seedBank(store, 'b1', const []);
      final questions = [
        Question(
          id: 'q-has',
          bankId: 'b1',
          type: QuestionType.single,
          question: 'has-answer 题',
          options: const {'A': '3', 'B': '4'},
          answer: const ['A'],
        ),
        Question(
          id: 'q-missing',
          bankId: 'b1',
          type: QuestionType.single,
          question: 'missing 题',
          options: const {'A': '3', 'B': '4'},
          answer: const [],
        ),
      ];
      final patches = await service.enrichMissingAnswers(questions: questions);
      expect(patches.keys, [1]);
      expect(patches[1]!.answer, ['B']);
      expect(patches[1]!.explanation, '选 B 因为');
      expect(runner.requests.single.prompt, contains('missing 题'));
      expect(runner.requests.single.prompt, isNot(contains('has-answer 题')));
    });

    test('超过 8 题分批；数组 / 字母串 / 判断 / 填空答案各自规范化', () async {
      final responses = [
        jsonEncode([
          for (var i = 0; i < 8; i++) {'answer': 'A', 'explanation': 'e$i'},
        ]),
        jsonEncode([
          {
            'answer': ['A', 'C'],
            'explanation': 'multi',
          },
          {'answer': '对', 'explanation': 'judge'},
          {'answer': '北京', 'explanation': 'blank'},
        ]),
      ];
      final (store, service, runner) = await setup(responses: responses);
      await seedBank(store, 'b1', const []);
      final questions = <Question>[
        for (var i = 0; i < 8; i++) choice('c$i', answer: const []),
        Question(
          id: 'm',
          bankId: 'b1',
          type: QuestionType.multiple,
          question: '多选题',
          options: const {'A': 'a', 'C': 'c'},
          answer: const [],
        ),
        Question(
          id: 'j',
          bankId: 'b1',
          type: QuestionType.judge,
          question: '判断题',
          answer: const [],
        ),
        Question(
          id: 'f',
          bankId: 'b1',
          type: QuestionType.blank,
          question: '首都是____',
          answer: const [],
        ),
      ];
      final patches = await service.enrichMissingAnswers(questions: questions);
      expect(runner.requests, hasLength(2)); // 8 + 3 两批
      expect(patches, hasLength(11));
      expect(patches[8]!.answer, ['A', 'C']); // 多选
      expect(patches[9]!.answer, ['true']); // 判断
      expect(patches[10]!.answer, ['北京']); // 填空
    });

    test('坏 JSON 批次安静跳过；null 条目不给补丁', () async {
      final (store, service, _) = await setup(
        responses: [
          'not json at all',
          jsonEncode([
            null,
            {'explanation': '只有解析'},
          ]),
        ],
      );
      await seedBank(store, 'b1', const []);
      final questions = [
        for (var i = 0; i < 10; i++) choice('q$i', answer: const []),
      ];
      final patches = await service.enrichMissingAnswers(questions: questions);
      expect(patches.keys, [9]); // 第二批第 2 条（全表下标 9）只有解析
      expect(patches[9]!.answer, isNull);
      expect(patches[9]!.explanation, '只有解析');
    });

    test('没有缺答案的题时不调用 LLM', () async {
      final (store, service, runner) = await setup();
      await seedBank(store, 'b1', const []);
      final patches = await service.enrichMissingAnswers(
        questions: [choice('a'), choice('b')],
      );
      expect(patches, isEmpty);
      expect(runner.requests, isEmpty);
    });
  });

  group('buildQuestionChatContext', () {
    test('包含题型 / 题干 / 选项 / 参考答案 / 我的作答 / 已有解析', () {
      final q = Question(
        id: 'q',
        bankId: 'b',
        type: QuestionType.single,
        question: '地球绕什么转？',
        options: const {'A': '月亮', 'B': '太阳'},
        answer: const ['B'],
        explanation: '万有引力。',
      );
      final context = buildShuatiQuestionContext(q, userAnswer: 'A');
      expect(context, contains('题型：单选'));
      expect(context, contains('题干：地球绕什么转？'));
      expect(context, contains('A. 月亮'));
      expect(context, contains('参考答案：B'));
      expect(context, contains('我的作答：A'));
      expect(context, contains('已有解析：万有引力。'));
    });

    test('判断题参考答案转成对 / 错；无答案显示占位', () {
      final judge = Question(
        id: 'j',
        bankId: 'b',
        type: QuestionType.judge,
        question: '水是液体',
        answer: const ['true'],
      );
      expect(buildShuatiQuestionContext(judge), contains('参考答案：对'));
      final noAnswer = Question(
        id: 'n',
        bankId: 'b',
        type: QuestionType.short,
        question: '简述',
        answer: const [],
      );
      expect(buildShuatiQuestionContext(noAnswer), contains('参考答案：（暂无答案）'));
    });
  });
}
