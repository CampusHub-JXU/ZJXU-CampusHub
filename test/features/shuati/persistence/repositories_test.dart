// 移植自 PWA tests/repositories/*.test.ts 与 tests/services/{practiceService,
// practiceSessionStore,wrongQuestionService,practiceAnswerService}.test.ts 的 DB 部分。
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/practice_selection.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';

import '../../../helpers/shuati_test_support.dart';

Future<ShuatiStore> storeWith(int n, {String bankId = 'b1'}) async {
  final store = await openTestStore();
  await seedBank(store, bankId, [
    for (var i = 0; i < n; i++) question('q$i', bankId, text: '题目 $i'),
  ]);
  return store;
}

void main() {
  group('recordRepo.test.ts', () {
    test('upsert 新记录返回自增 id', () async {
      final store = await storeWith(1);
      final id = await store.records.upsert(record('b1', 'q0'));
      expect(id, greaterThan(0));
    });

    test('给了 existingId：就地更新，返回同一 id', () async {
      final store = await storeWith(1);
      final id = await store.records.upsert(
        record('b1', 'q0', timestamp: 1000),
      );
      final same = await store.records.upsert(
        record(
          'b1',
          'q0',
          status: AnswerStatus.wrong,
          userAnswer: const ['B'],
          timestamp: 2000,
        ),
        existingId: id,
      );
      expect(same, id);
      final records = await store.records.getByBank('b1');
      expect(records, hasLength(1));
      expect(records.single.userAnswer, ['B']);
      expect(records.single.status, AnswerStatus.wrong);
      expect(records.single.timestamp, 2000);
    });

    test('existingId 对应行已不存在 → 新增一行', () async {
      final store = await storeWith(1);
      final id = await store.records.upsert(
        record('b1', 'q0'),
        existingId: 999,
      );
      expect(id, isNot(999));
      expect(await store.records.getByBank('b1'), hasLength(1));
    });

    test('getByBank 只返回该题库的记录', () async {
      final store = await storeWith(2);
      await seedBank(store, 'b2', [question('x', 'b2')]);
      await store.records.upsert(record('b1', 'q0'));
      await store.records.upsert(
        record('b1', 'q1', status: AnswerStatus.wrong),
      );
      await store.records.upsert(record('b2', 'x'));
      expect(await store.records.getByBank('b1'), hasLength(2));
      expect(await store.records.getByBank('nonexistent'), isEmpty);
    });
  });

  group('favoriteRepo.test.ts', () {
    test('isFavorited / toggle / 每个 (bank, question) 独立', () async {
      final store = await storeWith(1);
      await seedBank(
        store,
        'b2',
        [question('q0', 'b2')].map((q) => q.copyWith(id: 'q0b2')).toList(),
      );
      expect(await store.favorites.isFavorited('b1', 'q0'), isFalse);
      expect(await store.toggleFavorite('b1', 'q0'), isTrue);
      expect(await store.favorites.isFavorited('b1', 'q0'), isTrue);
      expect(await store.toggleFavorite('b2', 'q0b2'), isTrue);
      expect(await store.toggleFavorite('b1', 'q0'), isFalse);
      expect(await store.favorites.isFavorited('b1', 'q0'), isFalse);
      expect(await store.favorites.isFavorited('b2', 'q0b2'), isTrue);
    });

    test('questionIds 按收藏先后', () async {
      final store = await storeWith(3);
      await store.toggleFavorite('b1', 'q2');
      await store.toggleFavorite('b1', 'q0');
      expect(await store.favorites.questionIds('b1'), ['q2', 'q0']);
    });
  });

  group('wrongQuestionRepo.test.ts', () {
    test('marks a wrong question permanently', () async {
      final store = await storeWith(1);
      final id = await store.wrongQuestions.mark('b1', 'q0', timestamp: 100);
      expect(id, greaterThan(0));
      final w = (await store.wrongQuestions.find('b1', 'q0'))!;
      expect((w.firstWrongAt, w.lastWrongAt, w.wrongCount), (100, 100, 1));
    });

    test(
      'updates an existing wrong question instead of duplicating it',
      () async {
        final store = await storeWith(1);
        final first = await store.wrongQuestions.mark(
          'b1',
          'q0',
          timestamp: 100,
          lastRecordId: null,
        );
        final r1 = await store.records.upsert(record('b1', 'q0'));
        final second = await store.wrongQuestions.mark(
          'b1',
          'q0',
          timestamp: 200,
          lastRecordId: r1,
        );
        expect(second, first);
        expect(await store.wrongQuestions.getAll(), hasLength(1));
        final w = (await store.wrongQuestions.find('b1', 'q0'))!;
        expect(
          (w.firstWrongAt, w.lastWrongAt, w.wrongCount, w.lastRecordId),
          (100, 200, 2, r1),
        );
      },
    );

    test(
      'returns ids ordered by most recent wrong time; scopes by bank',
      () async {
        final store = await storeWith(2);
        await seedBank(store, 'b2', [question('z', 'b2')]);
        await store.wrongQuestions.mark('b1', 'q0', timestamp: 100);
        await store.wrongQuestions.mark('b1', 'q1', timestamp: 200);
        await store.wrongQuestions.mark('b2', 'z', timestamp: 300);
        expect(await store.wrongQuestions.questionIds('b1'), ['q1', 'q0']);
        expect(
          (await store.wrongQuestions.entriesByBank('b2')).single.questionId,
          'z',
        );
      },
    );

    test('removes a wrong question when requested explicitly', () async {
      final store = await storeWith(1);
      await store.wrongQuestions.mark('b1', 'q0', timestamp: 100);
      await store.wrongQuestions.remove('b1', 'q0');
      expect(await store.wrongQuestions.getAll(), isEmpty);
    });
  });

  group('practiceAnswerService.test.ts', () {
    test('adds wrong answers to the permanent wrong book', () async {
      final store = await storeWith(1);
      final id = await store.savePracticeAnswer(
        record(
          'b1',
          'q0',
          status: AnswerStatus.wrong,
          userAnswer: const ['B'],
          timestamp: 100,
        ),
      );
      expect((await store.records.getAll()).single.id, id);
      final w = (await store.wrongQuestions.getAll()).single;
      expect((w.bankId, w.questionId, w.lastRecordId), ('b1', 'q0', id));
    });

    test('does not remove the permanent wrong book entry after a later correct answer', () async {
      final store = await storeWith(1);
      final wrongId = await store.savePracticeAnswer(
        record(
          'b1',
          'q0',
          status: AnswerStatus.wrong,
          userAnswer: const ['B'],
          timestamp: 100,
        ),
      );
      await store.savePracticeAnswer(
        record('b1', 'q0', userAnswer: const ['A'], timestamp: 200),
        existingId: wrongId,
      );
      expect(
        (await store.records.getAll()).single.status,
        AnswerStatus.correct,
      );
      final w = (await store.wrongQuestions.getAll()).single;
      expect(w.wrongCount, 1);
    });

    test('同题再次答错：wrongCount 累加', () async {
      final store = await storeWith(1);
      final id = await store.savePracticeAnswer(
        record('b1', 'q0', status: AnswerStatus.wrong, timestamp: 100),
      );
      await store.savePracticeAnswer(
        record('b1', 'q0', status: AnswerStatus.wrong, timestamp: 200),
        existingId: id,
      );
      expect((await store.wrongQuestions.getAll()).single.wrongCount, 2);
    });
  });

  group('settingsRepo.test.ts', () {
    test('get 未设置的 key 返回 null；set 后 get；覆盖写入；对象值', () async {
      final store = await openTestStore();
      expect(await store.settings.get<Object>('nonexistent'), isNull);
      await store.settings.set('theme', 'dark');
      expect(await store.settings.get<String>('theme'), 'dark');
      await store.settings.set('theme', 'light');
      expect(await store.settings.get<String>('theme'), 'light');
      await store.settings.set('config', {
        'a': 1,
        'b': [2, 3],
      });
      expect(await store.settings.get<Map<String, dynamic>>('config'), {
        'a': 1,
        'b': [2, 3],
      });
    });

    test('getRaw 含 updatedAt；getAll 返回全部', () async {
      final store = await openTestStore();
      await store.settings.set('theme', 'dark', now: 42);
      expect((await store.settings.getRaw('theme'))!.updatedAt, 42);
      expect(await store.settings.getAll(), hasLength(1));
    });

    test('AI / 凭据类 key 一律拒绝写入（AI keys never persisted）', () async {
      final store = await openTestStore();
      for (final key in [
        'ai_apiKey',
        'ai_endpoint',
        'ai_model',
        'AI_KEY',
        'ai-token',
        'openaiApiKey',
        'my_api_key',
        'client_secret',
        'authToken',
        'password',
      ]) {
        expect(
          () => store.settings.set(key, 'secret'),
          throwsArgumentError,
          reason: key,
        );
      }
      expect(await store.settings.getAll(), isEmpty);
      await store.settings.set('airplane_mode', true); // 以 "ai" 开头但不是 ai_ 前缀
      expect(await store.settings.get<bool>('airplane_mode'), isTrue);
    });

    test('getForExport 再过滤一遍（纵深防御）', () async {
      final store = await openTestStore();
      await store.settings.set('theme', 'dark');
      // 绕过仓库直接写入，模拟「历史遗留 / 外部写入」
      await store.executor.insert('settings', {
        'key': 'ai_apiKey',
        'value_json': '"x"',
        'updated_at': 1,
      });
      expect((await store.settings.getForExport()).map((s) => s.key), [
        'theme',
      ]);
    });
  });

  group('practiceSessionStore.test.ts', () {
    Future<void> save(
      ShuatiStore s,
      String bank,
      PracticeMode mode,
      int index,
      List<String> ids, {
      QuestionType? type,
      int at = 1000,
    }) => s.saveLastPracticeSession(
      bankId: bank,
      mode: mode,
      currentIndex: index,
      questionIds: ids,
      typeFilter: type,
      updatedAt: at,
    );

    test('saves a global last session and a scoped session', () async {
      final store = await storeWith(2);
      await save(store, 'b1', PracticeMode.sequential, 3, ['q0', 'q1']);
      final global = (await store.sessions.load())!;
      final scoped = (await store.sessions.load(
        bankId: 'b1',
        mode: PracticeMode.sequential,
      ))!;
      expect(global.id, 'last');
      expect(global.currentIndex, 3);
      expect(global.typeFilter, isNull);
      expect(scoped.id, 'b1:sequential:all');
      expect(scoped.questionIds, ['q0', 'q1']);
    });

    test('keeps sessions isolated by bank and mode', () async {
      final store = await storeWith(1);
      await seedBank(store, 'b2', [question('q5', 'b2')]);
      await save(store, 'b1', PracticeMode.sequential, 1, ['q0']);
      await save(store, 'b2', PracticeMode.random, 4, ['q5'], at: 2000);
      expect(
        (await store.sessions.load(
          bankId: 'b1',
          mode: PracticeMode.sequential,
        ))!.currentIndex,
        1,
      );
      expect(
        (await store.sessions.load(
          bankId: 'b2',
          mode: PracticeMode.random,
        ))!.currentIndex,
        4,
      );
      expect((await store.sessions.load())!.bankId, 'b2');
    });

    test(
      'keeps type-filtered sessions isolated from unfiltered sessions',
      () async {
        final store = await storeWith(2);
        await save(store, 'b1', PracticeMode.sequential, 2, [
          'q0',
        ], type: QuestionType.single);
        await save(store, 'b1', PracticeMode.sequential, 5, ['q1'], at: 2000);
        final single = (await store.sessions.load(
          bankId: 'b1',
          mode: PracticeMode.sequential,
          typeFilter: QuestionType.single,
        ))!;
        final all = (await store.sessions.load(
          bankId: 'b1',
          mode: PracticeMode.sequential,
        ))!;
        expect((single.id, single.currentIndex), ('b1:sequential:single', 2));
        expect(single.questionIds, ['q0']);
        expect((all.id, all.currentIndex), ('b1:sequential:all', 5));
        expect(all.questionIds, ['q1']);
        expect(
          await store.sessions.load(
            bankId: 'b1',
            mode: PracticeMode.sequential,
            typeFilter: QuestionType.multiple,
          ),
          isNull,
        );
      },
    );

    test(
      'falls back to legacy scoped sessions only for unfiltered practice',
      () async {
        final store = await storeWith(1);
        await store.executor.insert('practice_sessions', {
          'id': 'b1:random',
          'bank_id': 'b1',
          'mode': 'random',
          'current_index': 1,
          'question_ids_json': '["q0"]',
          'updated_at': 1000,
        });
        expect(
          (await store.sessions.load(
            bankId: 'b1',
            mode: PracticeMode.random,
          ))!.id,
          'b1:random',
        );
        expect(
          await store.sessions.load(
            bankId: 'b1',
            mode: PracticeMode.random,
            typeFilter: QuestionType.single,
          ),
          isNull,
        );
      },
    );

    test('does not save exam sessions', () async {
      final store = await storeWith(1);
      await save(store, 'b1', PracticeMode.exam, 1, ['q0']);
      expect(await store.sessions.load(), isNull);
    });
  });

  group(
    'practiceService.test.ts（loadQuestions / loadPracticeSession，含 DB）',
    () {
      test('sequential 按导入顺序返回全部题目', () async {
        final store = await storeWith(5);
        expect(
          (await store.loadQuestions(
            'b1',
            PracticeMode.sequential,
          )).map((q) => q.id),
          ['q0', 'q1', 'q2', 'q3', 'q4'],
        );
      });

      test('wrong 模式使用永久错题本，最新记录做对后仍保留', () async {
        final store = await storeWith(2);
        await store.records.upsert(
          record('b1', 'q1', status: AnswerStatus.wrong, timestamp: 1),
        );
        await store.records.upsert(record('b1', 'q1', timestamp: 2));
        await store.wrongQuestions.mark('b1', 'q1', timestamp: 1);
        final qs = await store.loadQuestions('b1', PracticeMode.wrong);
        expect(qs.map((q) => q.id), ['q1']);
      });

      test('favorite 模式按收藏顺序返回题目', () async {
        final store = await storeWith(4);
        await store.toggleFavorite('b1', 'q2');
        await store.toggleFavorite('b1', 'q0');
        expect(
          (await store.loadQuestions(
            'b1',
            PracticeMode.favorite,
          )).map((q) => q.id),
          ['q2', 'q0'],
        );
      });

      test('exam 模式 shuffle + 截断；random 保留完整题单', () async {
        final store = await storeWith(10);
        expect(
          await store.loadQuestions(
            'b1',
            PracticeMode.exam,
            options: const PracticeLoadOptions(examCount: 3),
            random: Random(1),
          ),
          hasLength(3),
        );
        expect(
          await store.loadQuestions(
            'b1',
            PracticeMode.random,
            random: Random(2),
          ),
          hasLength(10),
        );
      });

      test('randomCount 只从未做题中抽取，题型过滤后同样', () async {
        final store = await storeWith(6);
        await store.records.upsert(record('b1', 'q1'));
        await store.records.upsert(
          record('b1', 'q3', status: AnswerStatus.wrong, timestamp: 2),
        );
        final qs = await store.loadQuestions(
          'b1',
          PracticeMode.random,
          options: const PracticeLoadOptions(randomCount: 2),
          random: Random(3),
        );
        expect(qs, hasLength(2));
        expect(qs.map((q) => q.id), everyElement(isNot(anyOf('q1', 'q3'))));
      });

      test('loadPracticeSession：恢复已答状态和起始位置；考试模式不恢复', () async {
        final store = await storeWith(5);
        await store.records.upsert(record('b1', 'q0'));
        await store.records.upsert(record('b1', 'q1'));
        final seq = await store.loadPracticeSession(
          'b1',
          PracticeMode.sequential,
        );
        expect(seq.startIndex, 2);
        expect(seq.results.keys.toSet(), {0, 1});
        final exam = await store.loadPracticeSession(
          'b1',
          PracticeMode.exam,
          options: const PracticeLoadOptions(shuffle: false),
        );
        expect(exam.results, isEmpty);
        expect(exam.startIndex, 0);
      });

      test(
        'resumeOrLoadPracticeSession：按保存的顺序与位置续练；random 重建；会话失效回退',
        () async {
          final store = await storeWith(5);
          await store.records.upsert(record('b1', 'q4'));
          await store.saveLastPracticeSession(
            bankId: 'b1',
            mode: PracticeMode.sequential,
            currentIndex: 2,
            questionIds: ['q4', 'q3', 'q2', 'q1', 'q0'],
          );
          final resumed = await store.resumeOrLoadPracticeSession(
            'b1',
            PracticeMode.sequential,
          );
          expect(resumed.questions.map((q) => q.id), [
            'q4',
            'q3',
            'q2',
            'q1',
            'q0',
          ]);
          expect(resumed.startIndex, 2);
          expect(resumed.results[0], AnswerStatus.correct);

          // random 总是重建完整题单
          await store.saveLastPracticeSession(
            bankId: 'b1',
            mode: PracticeMode.random,
            currentIndex: 1,
            questionIds: ['q0', 'q1'],
          );
          final random = await store.resumeOrLoadPracticeSession(
            'b1',
            PracticeMode.random,
            random: Random(1),
          );
          expect(random.questions, hasLength(5));

          // 保存的题都被删了 → 回退正常加载
          await store.saveLastPracticeSession(
            bankId: 'b1',
            mode: PracticeMode.favorite,
            currentIndex: 0,
            questionIds: ['gone'],
          );
          final fallback = await store.resumeOrLoadPracticeSession(
            'b1',
            PracticeMode.favorite,
          );
          expect(fallback.questions, isEmpty);
        },
      );
    },
  );

  group('wrongQuestionService.test.ts', () {
    test(
      'returns permanent wrong questions ordered by latest wrong time',
      () async {
        final store = await openTestStore();
        await seedBank(store, 'b1', [
          question('q-old', 'b1', text: 'Alpha concept'),
          question('q-new', 'b1', text: 'Beta concept'),
        ]);
        await store.wrongQuestions.mark('b1', 'q-old', timestamp: 100);
        await store.wrongQuestions.mark('b1', 'q-new', timestamp: 200);
        final result = await store.searchWrongQuestions('b1');
        expect(result.map((i) => i.question.id), ['q-new', 'q-old']);
        expect(result.first.entry.lastWrongAt, 200);
      },
    );

    test('filters by question text, option text, answer, and tags', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [
        question(
          'q1',
          'b1',
          text: 'React state',
          options: const {'A': 'useState', 'B': 'props'},
        ).copyWith(tags: const ['hooks']),
        question(
          'q2',
          'b1',
          text: 'IndexedDB storage',
          options: const {'A': 'cache', 'B': 'database'},
          answer: const ['B'],
        ).copyWith(tags: const ['pwa']),
      ]);
      await store.wrongQuestions.mark('b1', 'q1', timestamp: 100);
      await store.wrongQuestions.mark('b1', 'q2', timestamp: 200);
      expect(
        await store.searchWrongQuestions('b1', query: 'hooks'),
        hasLength(1),
      );
      expect(
        await store.searchWrongQuestions('b1', query: 'database'),
        hasLength(1),
      );
      expect(await store.searchWrongQuestions('b1', query: 'B'), hasLength(1));
      expect(await store.searchWrongQuestions('b1', query: 'missing'), isEmpty);
    });

    test('ignores missing or cross-bank question records', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1')]);
      await seedBank(store, 'b2', [question('q2', 'b2')]);
      await store.wrongQuestions.mark('b1', 'q1', timestamp: 100);
      // 手工制造一条跨库错题（FK 只保证题目存在，不保证同库）
      await store.executor.insert('wrong_questions', {
        'bank_id': 'b1',
        'question_id': 'q2',
        'first_wrong_at': 300,
        'last_wrong_at': 300,
        'wrong_count': 1,
      });
      final result = await store.searchWrongQuestions('b1');
      expect(result.map((i) => i.question.id), ['q1']);
    });
  });

  group('同源覆盖更新 bankRepo.updateBankQuestions', () {
    test('按 contentHash 复用旧 id、追加新题、删除旧题并级联清理，保留命中题的记录', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [
        question('old-keep', 'b1', text: 'keep'),
        question('old-remove', 'b1', text: 'remove'),
      ]);
      await store.records.upsert(record('b1', 'old-keep'));
      await store.records.upsert(record('b1', 'old-remove'));
      await store.toggleFavorite('b1', 'old-remove');
      await store.wrongQuestions.mark('b1', 'old-keep', timestamp: 1);
      await store.wrongQuestions.mark('b1', 'old-remove', timestamp: 1);
      await store.saveLastPracticeSession(
        bankId: 'b1',
        mode: PracticeMode.random,
        currentIndex: 0,
        questionIds: ['old-keep'],
      );

      final result = await store.updateBankQuestions('b1', [
        question('incoming-keep', 'b1', text: 'keep', answer: const ['B']),
        question('incoming-add', 'b1', text: 'new'),
      ]);

      expect((result.added, result.updated, result.removed), (1, 1, 1));
      expect((await store.banks.getBank('b1'))!.questionCount, 2);
      final ids = (await store.questions.getByBank('b1')).map((q) => q.id);
      expect(ids, ['old-keep', 'incoming-add']);
      expect((await store.questions.getByIds(['old-keep'])).single.answer, [
        'B',
      ]);
      expect(
        await store.records.getAll().then((r) => r.map((e) => e.questionId)),
        ['old-keep'],
      );
      expect(await store.favorites.getAll(), isEmpty);
      expect((await store.wrongQuestions.getAll()).map((w) => w.questionId), [
        'old-keep',
      ]);
      expect(
        await store.sessions.load(bankId: 'b1', mode: PracticeMode.random),
        isNull,
      );
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });
  });
}
