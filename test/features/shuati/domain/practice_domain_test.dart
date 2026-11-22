// 移植自 PWA tests/services/practiceService.test.ts（纯函数部分）、
// tests/pages/HomePage.test.ts（computeDailyAccuracy）、
// tests/services/practiceSessionStore.test.ts（id 规则），并补 QuestionCard 提交规则。
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/practice_attempt.dart';
import 'package:jxu_campus_hub/features/shuati/domain/practice_selection.dart';
import 'package:jxu_campus_hub/features/shuati/domain/practice_session.dart';
import 'package:jxu_campus_hub/features/shuati/domain/practice_stats.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';

Question q(
  String id, {
  QuestionType type = QuestionType.single,
  String bankId = 'b1',
  List<String> answer = const ['A'],
  Map<String, String>? options = const {'A': '选项A', 'B': '选项B'},
}) => Question(
  id: id,
  bankId: bankId,
  type: type,
  question: '题目 $id',
  options: options,
  answer: answer,
);

List<Question> seed(int n) => [for (var i = 0; i < n; i++) q('q$i')];

PracticeRecord rec(
  String qid,
  AnswerStatus status,
  int ts, {
  int? id,
  String bankId = 'b1',
}) => PracticeRecord(
  id: id,
  bankId: bankId,
  questionId: qid,
  userAnswer: const ['A'],
  status: status,
  timestamp: ts,
);

void main() {
  group('selectPracticeQuestions (loadQuestions)', () {
    test('sequential 模式返回全部题目（保持题库顺序，不洗牌）', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.sequential,
        bankId: 'b1',
        candidates: seed(5),
      );
      expect(qs.map((e) => e.id), ['q0', 'q1', 'q2', 'q3', 'q4']);
    });

    test('wrong 模式按错题条目顺序（最近答错在前）排序', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.wrong,
        bankId: 'b1',
        candidates: [q('q0'), q('q2')],
        orderedIds: ['q2', 'q0'],
      );
      expect(qs.map((e) => e.id), ['q2', 'q0']);
    });

    test('favorite 模式按收藏顺序返回题目', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.favorite,
        bankId: 'b1',
        candidates: [q('q0'), q('q2')],
        orderedIds: ['q2', 'q0'],
      );
      expect(qs.map((e) => e.id), ['q2', 'q0']);
    });

    test('wrong / favorite 过滤掉别的题库的题', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.wrong,
        bankId: 'b1',
        candidates: [
          q('q0'),
          q('x1', bankId: 'b2'),
        ],
        orderedIds: ['x1', 'q0'],
      );
      expect(qs.map((e) => e.id), ['q0']);
    });

    test('exam 模式支持 shuffle + 截断', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.exam,
        bankId: 'b1',
        candidates: seed(10),
        options: const PracticeLoadOptions(examCount: 3),
        random: Random(1),
      );
      expect(qs, hasLength(3));
    });

    test('random 模式保留完整题单（不传 randomCount 时不过滤已答）', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.random,
        bankId: 'b1',
        candidates: seed(5),
        records: [
          rec('q1', AnswerStatus.correct, 1),
          rec('q3', AnswerStatus.wrong, 2),
        ],
        random: Random(2),
      );
      expect(qs, hasLength(5));
      expect({for (final e in qs) e.id}, {'q0', 'q1', 'q2', 'q3', 'q4'});
    });

    test('randomCount 只从未做题中随机抽取指定题数', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.random,
        bankId: 'b1',
        candidates: seed(6),
        records: [
          rec('q1', AnswerStatus.correct, 1),
          rec('q3', AnswerStatus.wrong, 2),
        ],
        options: const PracticeLoadOptions(randomCount: 2),
        random: Random(3),
      );
      expect(qs, hasLength(2));
      expect(qs.map((e) => e.id), isNot(contains('q1')));
      expect(qs.map((e) => e.id), isNot(contains('q3')));
    });

    test('randomCount 按每题最新记录判断未做题', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.random,
        bankId: 'b1',
        candidates: seed(5),
        records: [
          rec('q0', AnswerStatus.wrong, 1),
          rec('q0', AnswerStatus.unanswered, 2),
          rec('q1', AnswerStatus.unanswered, 1),
          rec('q2', AnswerStatus.correct, 1),
          rec('q3', AnswerStatus.wrong, 1),
        ],
        options: const PracticeLoadOptions(randomCount: 5),
        random: Random(4),
      );
      expect({for (final e in qs) e.id}, {'q0', 'q1', 'q4'});
    });

    test('randomCount 在题型过滤后只抽对应题型的未做题', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.random,
        bankId: 'b1',
        candidates: [
          ...seed(3),
          for (var i = 0; i < 3; i++)
            q(
              'j$i',
              type: QuestionType.judge,
              answer: const ['true'],
              options: null,
            ),
        ],
        records: [
          rec('q0', AnswerStatus.correct, 1),
          rec('j0', AnswerStatus.wrong, 1),
        ],
        options: const PracticeLoadOptions(
          randomCount: 10,
          typeFilter: QuestionType.judge,
        ),
        random: Random(5),
      );
      expect(qs.map((e) => e.id).toList()..sort(), ['j1', 'j2']);
      expect(qs.every((e) => e.type == QuestionType.judge), isTrue);
    });

    test('显式 shuffle=false 时 random 模式也不洗牌', () {
      final qs = selectPracticeQuestions(
        mode: PracticeMode.random,
        bankId: 'b1',
        candidates: seed(5),
        options: const PracticeLoadOptions(shuffle: false),
      );
      expect(qs.map((e) => e.id), ['q0', 'q1', 'q2', 'q3', 'q4']);
    });

    test('shuffleList 是排列（不丢不重），固定种子可复现', () {
      final a = shuffleList(List.generate(50, (i) => i), random: Random(7));
      final b = shuffleList(List.generate(50, (i) => i), random: Random(7));
      expect(a, b);
      expect([...a]..sort(), List.generate(50, (i) => i));
    });
  });

  group('restoreFromRecords', () {
    test('无记录时返回空结果', () {
      final s = restoreFromRecords(
        mode: PracticeMode.sequential,
        questions: seed(3),
        records: [],
      );
      expect(s.results, isEmpty);
      expect(s.questionStates, isEmpty);
      expect(s.startIndex, 0);
    });

    test('恢复做题结果和题目状态', () {
      final s = restoreFromRecords(
        mode: PracticeMode.sequential,
        questions: seed(3),
        records: [
          rec('q0', AnswerStatus.correct, 1),
          rec('q1', AnswerStatus.wrong, 1),
        ],
      );
      expect(s.results[0], AnswerStatus.correct);
      expect(s.results[1], AnswerStatus.wrong);
      expect(s.questionStates, hasLength(2));
      expect(s.questionStates[0]!.submitted, isTrue);
    });

    test('sequential 模式跳到第一个未答题', () {
      final s = restoreFromRecords(
        mode: PracticeMode.sequential,
        questions: seed(5),
        records: [
          rec('q0', AnswerStatus.correct, 1),
          rec('q1', AnswerStatus.correct, 1),
        ],
      );
      expect(s.startIndex, 2);
    });

    test('sequential 全部答完跳到最后一题', () {
      final s = restoreFromRecords(
        mode: PracticeMode.sequential,
        questions: seed(3),
        records: [
          for (var i = 0; i < 3; i++) rec('q$i', AnswerStatus.correct, 1),
        ],
      );
      expect(s.startIndex, 2);
    });

    test('wrong 模式恢复 DB 结果但不恢复题目状态（允许重新作答）', () {
      final s = restoreFromRecords(
        mode: PracticeMode.wrong,
        questions: seed(2),
        records: [rec('q0', AnswerStatus.wrong, 1)],
      );
      expect(s.questionStates, isEmpty);
      expect(s.results[0], AnswerStatus.wrong);
      expect(s.startIndex, 0);
    });

    test('random 模式跳到第一道未做题', () {
      final s = restoreFromRecords(
        mode: PracticeMode.random,
        questions: seed(4),
        records: [
          rec('q0', AnswerStatus.correct, 1),
          rec('q1', AnswerStatus.wrong, 2),
        ],
      );
      expect(s.results[0], AnswerStatus.correct);
      expect(s.results[1], AnswerStatus.wrong);
      expect(s.startIndex, 2);
    });

    test('只保留每题最新记录；同时间戳按自增 id', () {
      final a = restoreFromRecords(
        mode: PracticeMode.sequential,
        questions: seed(1),
        records: [
          rec('q0', AnswerStatus.wrong, 1),
          rec('q0', AnswerStatus.correct, 2),
        ],
      );
      expect(a.results[0], AnswerStatus.correct);
      final b = restoreFromRecords(
        mode: PracticeMode.sequential,
        questions: seed(1),
        records: [
          rec('q0', AnswerStatus.wrong, 1, id: 1),
          rec('q0', AnswerStatus.correct, 1, id: 2),
        ],
      );
      expect(b.results[0], AnswerStatus.correct);
    });

    test('不在题单里的记录被忽略；status=unanswered 的最新记录仍算「已处理」（PWA 真值语义）', () {
      final s = restoreFromRecords(
        mode: PracticeMode.sequential,
        questions: seed(3),
        records: [
          rec('zzz', AnswerStatus.correct, 1),
          rec('q0', AnswerStatus.unanswered, 1),
        ],
      );
      expect(s.results.keys, [0]);
      expect(s.startIndex, 1);
    });
  });

  group('computeStats', () {
    test('空结果', () {
      final s = computeStats({}, 10);
      expect((s.answered, s.correct, s.wrong, s.isFinished), (0, 0, 0, false));
      expect(s.accuracy, 0);
    });
    test('部分完成', () {
      final s = computeStats({
        0: AnswerStatus.correct,
        1: AnswerStatus.wrong,
      }, 10);
      expect(
        (s.answered, s.correct, s.wrong, s.accuracy, s.isFinished),
        (2, 1, 1, 50, false),
      );
    });
    test('忽略 unanswered 和越界结果', () {
      final s = computeStats({
        0: AnswerStatus.correct,
        1: AnswerStatus.unanswered,
        5: AnswerStatus.wrong,
      }, 2);
      expect(
        (s.answered, s.correct, s.wrong, s.accuracy, s.isFinished),
        (1, 1, 0, 100, false),
      );
    });
    test('全部完成 / 正确率计算（四舍五入）', () {
      expect(
        computeStats({
          0: AnswerStatus.correct,
          1: AnswerStatus.correct,
        }, 2).isFinished,
        isTrue,
      );
      expect(
        computeStats({
          0: AnswerStatus.correct,
          1: AnswerStatus.wrong,
          2: AnswerStatus.wrong,
          3: AnswerStatus.wrong,
        }, 4).accuracy,
        25,
      );
      expect(
        computeStats({
          0: AnswerStatus.correct,
          1: AnswerStatus.correct,
          2: AnswerStatus.wrong,
        }, 3).accuracy,
        67,
      );
    });
  });

  group('localStorage 顺序进度（兼容 / 迁移用）', () {
    test('合法 JSON 解析', () {
      final saved = parseSavedProgress(
        '{"currentIndex":5,"results":{"0":"correct"}}',
        PracticeMode.sequential,
      );
      expect(saved!.currentIndex, 5);
      expect(saved.results, {0: AnswerStatus.correct});
    });
    test('非 sequential 模式不读取', () {
      expect(
        parseSavedProgress(
          '{"currentIndex":5,"results":{}}',
          PracticeMode.random,
        ),
        isNull,
      );
    });
    test('损坏的 JSON / 结构返回 null', () {
      expect(
        parseSavedProgress('invalid{json', PracticeMode.sequential),
        isNull,
      );
      expect(
        parseSavedProgress(
          '{"currentIndex":"2","results":null}',
          PracticeMode.sequential,
        ),
        isNull,
      );
      expect(parseSavedProgress(null, PracticeMode.sequential), isNull);
    });
    test('读取时清理无效结果状态与取整', () {
      final saved = parseSavedProgress(
        '{"currentIndex":2.8,"results":{"0":"correct","1":"unanswered","-1":"wrong","bad":"correct"}}',
        PracticeMode.sequential,
      );
      expect(saved!.currentIndex, 2);
      expect(saved.results, {0: AnswerStatus.correct});
    });
  });

  group('PracticeNavigator', () {
    Map<int, AnswerStatus> done(List<int> idx) => {
      for (final i in idx) i: AnswerStatus.correct,
    };

    test('顺序模式线性移动并钳位', () {
      final nav = PracticeNavigator(
        mode: PracticeMode.sequential,
        total: 3,
        results: const {},
      );
      expect(nav.next(0), 1);
      expect(nav.next(2), 2);
      expect(nav.previous(0), 0);
      expect(nav.prevDisabled(0), isTrue);
      expect(nav.nextDisabled(2), isTrue);
    });

    test('全量随机只在未答题之间跳转，找不到则原地不动', () {
      final nav = PracticeNavigator(
        mode: PracticeMode.random,
        total: 5,
        results: done([1, 2]),
      );
      expect(nav.next(0), 3);
      expect(nav.previous(3), 0);
      expect(nav.previous(0), 0);
      expect(nav.nextDisabled(4), isTrue);
      expect(nav.prevDisabled(0), isTrue);
    });

    test('随机抽题（有 randomCount）按线性移动，全部答完显示「结束」', () {
      final nav = PracticeNavigator(
        mode: PracticeMode.random,
        total: 3,
        results: done([0, 1, 2]),
        randomCount: 3,
      );
      expect(nav.isRandomSample, isTrue);
      expect(nav.next(0), 1);
      expect(nav.showFinish(computeStats(done([0, 1, 2]), 3)), isTrue);
      expect(nav.showFinish(computeStats(done([0]), 3)), isFalse);
    });

    test('考试模式答完显示「结束」，顺序模式从不', () {
      final exam = PracticeNavigator(
        mode: PracticeMode.exam,
        total: 1,
        results: done([0]),
      );
      expect(exam.showFinish(computeStats(done([0]), 1)), isTrue);
      final seq = PracticeNavigator(
        mode: PracticeMode.sequential,
        total: 1,
        results: done([0]),
      );
      expect(seq.showFinish(computeStats(done([0]), 1)), isFalse);
    });
  });

  group('会话 id 与续练 (practiceSessionStore.test.ts)', () {
    test('scoped id：有/无题型过滤；legacy id；last', () {
      expect(
        scopedSessionId('b1', PracticeMode.sequential, null),
        'b1:sequential:all',
      );
      expect(
        scopedSessionId('b1', PracticeMode.sequential, QuestionType.single),
        'b1:sequential:single',
      );
      expect(legacyScopedSessionId('b1', PracticeMode.random), 'b1:random');
      expect(lastSessionId, 'last');
    });

    PracticeSessionRecord session({
      String bankId = 'b1',
      PracticeMode mode = PracticeMode.sequential,
      QuestionType? type,
      int index = 1,
      List<String> ids = const ['q0', 'q1', 'q2'],
    }) => PracticeSessionRecord(
      id: 'x',
      bankId: bankId,
      mode: mode,
      typeFilter: type,
      currentIndex: index,
      questionIds: ids,
      updatedAt: 1,
    );

    test('pickResumeSession：优先 scoped，其次三项都相同的全局 last', () {
      final scoped = session(index: 4);
      final global = session(index: 9);
      expect(
        pickResumeSession(
          bankId: 'b1',
          mode: PracticeMode.sequential,
          typeFilter: null,
          scoped: scoped,
          globalLast: global,
        ),
        same(scoped),
      );
      expect(
        pickResumeSession(
          bankId: 'b1',
          mode: PracticeMode.sequential,
          typeFilter: null,
          scoped: null,
          globalLast: global,
        ),
        same(global),
      );
      expect(
        pickResumeSession(
          bankId: 'b2',
          mode: PracticeMode.sequential,
          typeFilter: null,
          scoped: null,
          globalLast: global,
        ),
        isNull,
      );
      expect(
        pickResumeSession(
          bankId: 'b1',
          mode: PracticeMode.sequential,
          typeFilter: QuestionType.single,
          scoped: null,
          globalLast: global,
        ),
        isNull,
      );
    });

    test('resumePracticeSession：按保存的题序复原，位置钳在范围内，已删除题被跳过', () {
      final available = [q('q2'), q('q0')]; // q1 已被删除
      final resumed = resumePracticeSession(
        mode: PracticeMode.sequential,
        saved: session(index: 9),
        availableQuestions: available,
        records: [rec('q0', AnswerStatus.correct, 1)],
      )!;
      expect(resumed.questions.map((e) => e.id), ['q0', 'q2']);
      expect(resumed.startIndex, 1); // 钳到最后一题，而不是「第一个未答」
      expect(resumed.results[0], AnswerStatus.correct);
    });

    test('resumePracticeSession：random 不续练；无会话 / 题全没了 → null', () {
      expect(
        resumePracticeSession(
          mode: PracticeMode.random,
          saved: session(mode: PracticeMode.random),
          availableQuestions: seed(3),
          records: const [],
        ),
        isNull,
      );
      expect(
        resumePracticeSession(
          mode: PracticeMode.sequential,
          saved: null,
          availableQuestions: seed(3),
          records: const [],
        ),
        isNull,
      );
      expect(
        resumePracticeSession(
          mode: PracticeMode.sequential,
          saved: session(),
          availableQuestions: const [],
          records: const [],
        ),
        isNull,
      );
    });
  });

  group('submitAnswer / selfGrade / redo（QuestionCard 规则）', () {
    QuestionState picked(List<String> a, {String blank = ''}) => QuestionState(
      userAnswer: a,
      blankInput: blank,
      submitted: false,
      status: AnswerStatus.unanswered,
    );

    test('单选答对：保存记录，立即展示答案模式自动前进', () {
      final d = submitAnswer(
        question: q('q'),
        state: picked(['A']),
        showAnswerImmediately: true,
      );
      expect(d.state.submitted, isTrue);
      expect(d.state.status, AnswerStatus.correct);
      expect(d.persist, AnswerStatus.correct);
      expect(d.persistedAnswer, ['A']);
      expect(d.autoAdvance, isTrue);
    });

    test('答错：保存记录但不自动前进', () {
      final d = submitAnswer(
        question: q('q'),
        state: picked(['B']),
        showAnswerImmediately: true,
      );
      expect(d.persist, AnswerStatus.wrong);
      expect(d.autoAdvance, isFalse);
    });

    test('考试模式答对也不自动前进', () {
      final d = submitAnswer(
        question: q('q'),
        state: picked(['A']),
        showAnswerImmediately: false,
      );
      expect(d.persist, AnswerStatus.correct);
      expect(d.autoAdvance, isFalse);
    });

    test('已提交 / 空答案 / 题目不可作答 → noop', () {
      final submitted = picked(['A']).copyWith(submitted: true);
      expect(
        submitAnswer(
          question: q('q'),
          state: submitted,
          showAnswerImmediately: true,
        ).persist,
        isNull,
      );
      expect(
        submitAnswer(
          question: q('q'),
          state: picked([]),
          showAnswerImmediately: true,
        ).persist,
        isNull,
      );
      expect(
        submitAnswer(
          question: q('q', answer: const []),
          state: picked(['A']),
          showAnswerImmediately: true,
        ).state.submitted,
        isFalse,
      );
      expect(
        submitAnswer(
          question: q('q', options: const {}),
          state: picked(['A']),
          showAnswerImmediately: true,
        ).state.submitted,
        isFalse,
      );
    });

    test('填空题（立即展示模式）：提交后待自评，不保存记录', () {
      final blank = q(
        'b',
        type: QuestionType.blank,
        options: null,
        answer: const ['北京'],
      );
      final d = submitAnswer(
        question: blank,
        state: picked([], blank: ' 北京 '),
        showAnswerImmediately: true,
      );
      expect(d.state.submitted, isTrue);
      expect(d.state.status, AnswerStatus.unanswered);
      expect(d.persist, isNull);
      expect(d.state.userAnswer, ['北京']);

      final graded = selfGrade(
        state: d.state,
        grade: AnswerStatus.correct,
        showAnswerImmediately: true,
      );
      expect(graded.persist, AnswerStatus.correct);
      expect(graded.persistedAnswer, ['北京']);
      expect(graded.autoAdvance, isTrue);

      final regraded = selfGrade(
        state: graded.state,
        grade: AnswerStatus.wrong,
        showAnswerImmediately: true,
      );
      expect(regraded.persist, AnswerStatus.wrong);
      expect(regraded.autoAdvance, isFalse);
    });

    test('填空题（考试模式）：直接判分并保存', () {
      final blank = q(
        'b',
        type: QuestionType.short,
        options: null,
        answer: const ['Hello'],
      );
      final d = submitAnswer(
        question: blank,
        state: picked([], blank: 'hello'),
        showAnswerImmediately: false,
      );
      expect(d.persist, AnswerStatus.correct);
    });

    test('selfGrade 必须已提交', () {
      final d = selfGrade(
        state: picked([]),
        grade: AnswerStatus.correct,
        showAnswerImmediately: true,
      );
      expect(d.persist, isNull);
    });

    test('toggleOption：单选/判断替换、多选切换、已提交不可改', () {
      expect(toggleOption(QuestionType.single, ['A'], 'B', submitted: false), [
        'B',
      ]);
      expect(toggleOption(QuestionType.judge, [], 'true', submitted: false), [
        'true',
      ]);
      expect(
        toggleOption(QuestionType.multiple, ['A'], 'B', submitted: false),
        ['A', 'B'],
      );
      expect(
        toggleOption(QuestionType.multiple, ['A', 'B'], 'A', submitted: false),
        ['B'],
      );
      expect(toggleOption(QuestionType.single, ['A'], 'B', submitted: true), [
        'A',
      ]);
    });

    test('redo：丢弃 recordId，下次作答新增记录', () {
      final state = QuestionState(
        userAnswer: const ['B'],
        submitted: true,
        status: AnswerStatus.wrong,
        recordId: 7,
      );
      final fresh = redo();
      expect(fresh.recordId, isNull);
      expect(fresh.submitted, isFalse);
      expect(state.recordId, 7);
    });

    test('自动前进只在「答对 + 立即展示」时成立，延迟 650ms', () {
      expect(
        shouldAutoAdvance(AnswerStatus.correct, showAnswerImmediately: true),
        isTrue,
      );
      expect(
        shouldAutoAdvance(AnswerStatus.wrong, showAnswerImmediately: true),
        isFalse,
      );
      expect(
        shouldAutoAdvance(AnswerStatus.correct, showAnswerImmediately: false),
        isFalse,
      );
      expect(kAutoAdvanceDelay, const Duration(milliseconds: 650));
    });
  });

  group('统计（HomePage / BanksPage）', () {
    PracticeRecord day(AnswerStatus s, int daysAgo, DateTime now) =>
        PracticeRecord(
          bankId: 'b1',
          questionId: 'q1',
          userAnswer: const ['A'],
          status: s,
          timestamp: now.millisecondsSinceEpoch - daysAgo * 86400000,
        );

    final now = DateTime(2026, 10, 15, 12);

    test('computeDailyAccuracy：空记录返回 7 天全 0', () {
      final r = computeDailyAccuracy(const [], now: now);
      expect(r, hasLength(7));
      expect(r.every((d) => d.value == 0), isTrue);
      expect(r.last.label, '10/15');
    });
    test('今天的记录正确反映在当天（2/3 → 67）', () {
      final r = computeDailyAccuracy([
        day(AnswerStatus.correct, 0, now),
        day(AnswerStatus.correct, 0, now),
        day(AnswerStatus.wrong, 0, now),
      ], now: now);
      expect(r.last.value, 67);
    });
    test('7 天前计入、8 天前忽略、unanswered 不影响、每天独立', () {
      expect(
        computeDailyAccuracy([
          day(AnswerStatus.correct, 6, now),
        ], now: now).first.value,
        100,
      );
      expect(
        computeDailyAccuracy([
          day(AnswerStatus.correct, 8, now),
        ], now: now).every((d) => d.value == 0),
        isTrue,
      );
      expect(
        computeDailyAccuracy([
          day(AnswerStatus.unanswered, 0, now),
        ], now: now).last.value,
        0,
      );
      final r = computeDailyAccuracy([
        day(AnswerStatus.correct, 0, now),
        day(AnswerStatus.wrong, 1, now),
      ], now: now);
      expect((r.last.value, r[5].value), (100, 0));
    });

    test('computeHomeStats：进度按 (题库,题) 去重，正确率按全部有效作答', () {
      const banks = [
        QuestionBank(
          id: 'b1',
          name: 'a',
          createdAt: 1,
          updatedAt: 1,
          questionCount: 10,
        ),
        QuestionBank(
          id: 'b2',
          name: 'b',
          createdAt: 1,
          updatedAt: 1,
          questionCount: 10,
        ),
      ];
      final stats = computeHomeStats(
        banks: banks,
        records: [
          rec('q1', AnswerStatus.wrong, 1),
          rec('q1', AnswerStatus.correct, 2),
          rec('q2', AnswerStatus.correct, 3),
          rec('q1', AnswerStatus.unanswered, 4),
        ],
        now: now,
      );
      expect(stats.totalQuestions, 20);
      expect(stats.answered, 2);
      expect(stats.accuracy, 67);
      expect(stats.completionPct, 10);
      expect(stats.bankCount, 2);
      expect(
        computeHomeStats(banks: banks, records: const [], now: now).accuracy,
        isNull,
      );
    });

    test('computeBankStats：wrong 是错误作答次数', () {
      const bank = QuestionBank(
        id: 'b1',
        name: 'a',
        createdAt: 1,
        updatedAt: 1,
        questionCount: 4,
      );
      final s = computeBankStats(bank, [
        rec('q1', AnswerStatus.wrong, 1),
        rec('q1', AnswerStatus.wrong, 2),
        rec('q2', AnswerStatus.correct, 3),
        rec('q9', AnswerStatus.correct, 4, bankId: 'other'),
      ]);
      expect(
        (s.wrong, s.uniqueAnswered, s.progress, s.accuracy),
        (2, 2, 50, 33),
      );
    });

    test('summarizeForModes：考试 / 随机可选题数', () {
      final qs = seed(30);
      final sum = summarizeForModes(
        questions: qs,
        records: [
          for (var i = 0; i < 25; i++) rec('q$i', AnswerStatus.correct, i),
        ],
      );
      expect(sum.totalCount, 30);
      expect(sum.unansweredCount, 5);
      expect(sum.examOptions, [20, 30]);
      expect(sum.randomOptions, [5]);
      expect(sum.typeCounts[QuestionType.single], 30);
    });

    test('clampCustomRandomCount', () {
      expect(clampCustomRandomCount(0, 10), 1);
      expect(clampCustomRandomCount(99, 10), 10);
      expect(clampCustomRandomCount(3.9, 10), 3);
      expect(clampCustomRandomCount(5, 0), 1);
    });
  });
}
