// 与 PWA 原始 TypeScript 的逐条差分测试。
//
// test/fixtures/shuati/golden_expected.json 由 tools/shuati_golden/generate_golden.mjs
// 对 shuatipwa 源码（src/domain/*、src/services/importService.ts 的纯函数部分）运行得到，
// 输入语料为 golden_corpus.json。这里把同一语料喂给 Dart 移植版，输出必须逐字段一致。
//
// 对应 PWA 源：
//   questionParser.ts   parseTextToQuestions / inferQuestionType
//   importService.ts    parseCSVRows / parseRows / parseTextQuestions / normalizeQuestion
//   questionFingerprint buildContentKey / buildAnswerKey / attachQuestionHashes
//   answerJudge.ts      checkAnswer
//   wrongQuestion.ts    getCurrentWrongQuestionIds
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/answer_judge.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_fingerprint.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_text_parser.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_type.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/domain/wrong_question.dart';
import 'package:jxu_campus_hub/features/shuati/import/question_normalizer.dart';
import 'package:jxu_campus_hub/features/shuati/import/raw_question_parsers.dart';

Map<String, Object?> _load(String name) =>
    jsonDecode(File('test/fixtures/shuati/$name').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _parsedJson(ParsedQuestion q) => {
  'question': q.question,
  if (q.options != null) 'options': q.options,
  'answer': q.answer,
  if (q.explanation != null) 'explanation': q.explanation,
  if (q.optionExplanations != null) 'optionExplanations': q.optionExplanations,
};

Map<String, Object?> _rawJson(RawQuestion q) => {
  'question': q.question,
  if (q.optionsMap != null) 'options': q.optionsMap,
  'answer': q.answer,
  if (q.explanation != null) 'explanation': q.explanation,
  if (q.optionExplanationsMap != null)
    'optionExplanations': q.optionExplanationsMap,
  if (q.type != null) 'type': q.type,
};

List<Object?> _list(Object? v) => (v! as List).cast<Object?>();
Map<String, Object?> _map(Object? v) => (v! as Map).cast<String, Object?>();

void main() {
  final corpus = _load('golden_corpus.json');
  final expected = _load('golden_expected.json');

  group('golden parity (PWA 原始 TS 输出)', () {
    test('语料规模（防止黄金文件被意外清空）', () {
      expect(_list(corpus['textCases']).length, greaterThan(50));
      expect(_list(corpus['csvCases']).length, greaterThan(20));
      expect(
        _list(expected['textParse']).length,
        _list(corpus['textCases']).length,
      );
    });

    test('parseTextToQuestions 与 questionParser.ts 逐条一致', () {
      final cases = _list(corpus['textCases']);
      final golden = _list(expected['textParse']);
      for (final (i, c) in cases.indexed) {
        final name = _map(c)['name'];
        final text = _map(c)['text']! as String;
        final want = _list(_map(golden[i])['result']);
        final got = [
          for (final q in parseTextToQuestions(text)) _parsedJson(q),
        ];
        expect(got, equals(want), reason: 'textCase "$name"');
      }
    });

    test('parseCsvRows 与 importService.parseCSVRows 逐条一致', () {
      final cases = _list(corpus['csvCases']);
      final golden = _list(expected['csvRows']);
      for (final (i, c) in cases.indexed) {
        final name = _map(c)['name'];
        final want = [
          for (final row in _list(_map(golden[i])['rows']))
            [for (final cell in _list(row)) cell as String],
        ];
        expect(
          parseCsvRows(_map(c)['text']! as String),
          equals(want),
          reason: 'csvRows "$name"',
        );
      }
    });

    test('CSV 全链路 parseRows 与 importService.parseCSV 逐条一致', () {
      final cases = _list(corpus['csvCases']);
      final golden = _list(expected['csv']);
      for (final (i, c) in cases.indexed) {
        final name = _map(c)['name'];
        final want = _list(_map(golden[i])['result']);
        final got = [
          for (final q in parseRows(parseCsvRows(_map(c)['text']! as String)))
            _rawJson(q),
        ];
        expect(got, equals(want), reason: 'csv "$name"');
      }
    });

    test('旧文本兜底 parseLegacyTextQuestions 与 parseTextQuestions 一致', () {
      final cases = _list(corpus['legacyCases']);
      final golden = _list(expected['legacyText']);
      for (final (i, c) in cases.indexed) {
        final name = _map(c)['name'];
        final want = _list(_map(golden[i])['result']);
        final got = [
          for (final q in parseLegacyTextQuestions(_map(c)['text']! as String))
            _rawJson(q),
        ];
        expect(got, equals(want), reason: 'legacy "$name"');
      }
    });

    test('normalizeQuestion + contentHash/answerHash 与 PWA 逐字节一致', () {
      final cases = _list(corpus['rawCases']);
      final golden = _list(expected['normalize']);
      for (final (i, c) in cases.indexed) {
        final name = _map(c)['name'];
        final outcome = parseJsonQuestions([_map(c)['raw']]);
        expect(outcome.questions, hasLength(1), reason: 'raw "$name" 应被接受');
        var n = 0;
        final q = attachQuestionHash(
          normalizeQuestion(
            outcome.questions.single,
            'BANK',
            newId: () => 'GEN-${++n}',
          ),
        );
        final want = _map(_map(golden[i])['result']);
        expect(q.toJson(), equals(want), reason: 'raw "$name"');
      }
    });

    test('checkAnswer 与 answerJudge.ts 一致', () {
      final cases = _list(corpus['judgeCases']);
      final golden = _list(expected['judge']);
      for (final (i, c) in cases.indexed) {
        final m = _map(c);
        final q = Question.tryFromJson(m['question'])!;
        final user = [for (final a in _list(m['user'])) a as String];
        expect(
          checkAnswer(q, user).name,
          _map(golden[i])['result'],
          reason: 'judge "${m['name']}"',
        );
      }
    });

    test('getCurrentWrongQuestionIds 与 wrongQuestion.ts 一致（含顺序）', () {
      final cases = _list(corpus['wrongCases']);
      final golden = _list(expected['wrongIds']);
      for (final (i, c) in cases.indexed) {
        final m = _map(c);
        final records = [
          for (final r in _list(m['records'])) PracticeRecord.tryFromJson(r)!,
        ];
        expect(
          getCurrentWrongQuestionIds(records),
          equals(_list(_map(golden[i])['result'])),
          reason: 'wrong "${m['name']}"',
        );
      }
    });

    test(
      'buildContentKey / buildAnswerKey / SHA-256 与 questionFingerprint.ts 一致',
      () {
        final cases = _list(corpus['fingerprintCases']);
        final golden = _list(expected['fingerprint']);
        for (final (i, c) in cases.indexed) {
          final m = _map(c);
          final q = Question.tryFromJson(m['question'])!;
          final g = _map(golden[i]);
          expect(
            buildContentKey(q),
            g['contentKey'],
            reason: 'content "${m['name']}"',
          );
          expect(
            buildAnswerKey(q),
            g['answerKey'],
            reason: 'answerKey "${m['name']}"',
          );
          final hashed = attachQuestionHash(q);
          expect(
            hashed.contentHash,
            g['contentHash'],
            reason: 'contentHash "${m['name']}"',
          );
          expect(
            hashed.answerHash,
            g['answerHash'],
            reason: 'answerHash "${m['name']}"',
          );
        }
      },
    );

    test('inferQuestionType 与 questionParser.ts 一致', () {
      final cases = _list(corpus['inferCases']);
      final golden = _list(expected['infer']);
      for (final (i, c) in cases.indexed) {
        final m = _map(c);
        final options = m['options'] == null
            ? null
            : {
                for (final e in _map(m['options']).entries)
                  e.key: e.value! as String,
              };
        expect(
          inferQuestionType(
            [for (final a in _list(m['answer'])) a as String],
            options: options,
            question: (m['question'] as String?) ?? '',
          ).name,
          _map(golden[i])['result'],
          reason: 'infer "${m['name']}"',
        );
      }
    });
  });
}
