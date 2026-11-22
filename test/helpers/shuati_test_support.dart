// 刷题助手测试公共件：内存 SQLite（sqflite_common_ffi）与样例构造器。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_fingerprint.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_database.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiReady = false;

/// 打开一个全新的内存库并在测试结束时关闭（关闭即销毁内存库，下个测试重新开始）。
Future<ShuatiStore> openTestStore({
  int? schemaVersion,
  Map<int, ShuatiMigration>? migrations,
}) async {
  final database = await openTestDatabase(
    schemaVersion: schemaVersion,
    migrations: migrations,
  );
  return ShuatiStore(database.db);
}

Future<ShuatiDatabase> openTestDatabase({
  String? path,
  int? schemaVersion,
  Map<int, ShuatiMigration>? migrations,
  bool closeAtTearDown = true,
}) async {
  if (!_ffiReady) {
    sqfliteFfiInit();
    _ffiReady = true;
  }
  final database = await ShuatiDatabase.open(
    path: path ?? inMemoryDatabasePath,
    factory: databaseFactoryFfi,
    schemaVersion: schemaVersion,
    migrationTable: migrations,
    singleInstance: path != null,
  );
  if (closeAtTearDown) addTearDown(database.close);
  return database;
}

/// 每张表的行数（断言「没有副作用」「没有重复」用）。
Future<Map<String, int>> tableCounts(ShuatiStore store) async {
  final counts = <String, int>{};
  for (final table in ShuatiSchema.tablesChildFirst) {
    final rows = await store.executor.rawQuery(
      'SELECT COUNT(*) AS c FROM $table',
    );
    counts[table] = rows.first['c']! as int;
  }
  return counts;
}

QuestionBank bank(
  String id, {
  String? name,
  int questionCount = 0,
  int createdAt = 1,
  int updatedAt = 1,
  String? sourceFileName,
  String? sourceFileExt,
}) => QuestionBank(
  id: id,
  name: name ?? 'Bank $id',
  createdAt: createdAt,
  updatedAt: updatedAt,
  questionCount: questionCount,
  sourceFileName: sourceFileName,
  sourceFileExt: sourceFileExt,
);

/// 单选样例题（自动带 hash）。
Question question(
  String id,
  String bankId, {
  QuestionType type = QuestionType.single,
  String? text,
  Map<String, String>? options,
  List<String> answer = const ['A'],
  bool hashed = true,
  String? explanation,
}) {
  final q = Question(
    id: id,
    bankId: bankId,
    type: type,
    question: text ?? 'Question $id',
    options:
        options ?? (type.isChoice ? const {'A': 'Alpha', 'B': 'Beta'} : null),
    answer: answer,
    explanation: explanation,
  );
  return hashed ? attachQuestionHash(q) : q;
}

PracticeRecord record(
  String bankId,
  String questionId, {
  AnswerStatus status = AnswerStatus.correct,
  int timestamp = 1000,
  List<String> userAnswer = const ['A'],
  int? id,
}) => PracticeRecord(
  id: id,
  bankId: bankId,
  questionId: questionId,
  userAnswer: userAnswer,
  status: status,
  timestamp: timestamp,
);

/// 插入题库 + 题目（题目按给定顺序）。
Future<void> seedBank(
  ShuatiStore store,
  String bankId,
  List<Question> questions, {
  String? name,
}) async {
  await store.banks.insertBank(
    bank(bankId, name: name, questionCount: questions.length),
  );
  await store.questions.insertAll(questions);
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// 构造 PWA 风格备份 JSON（合成数据，无真实用户内容）。
Map<String, Object?> syntheticBackup({
  int version = 3,
  int banks = 2,
  int questionsPerBank = 3,
  bool withRecords = true,
  bool withWrong = true,
  bool withAi = true,
  bool withSettings = true,
  bool withHashes = true,
}) {
  final bankList = <Map<String, Object?>>[];
  final questions = <String, List<Map<String, Object?>>>{};
  final records = <Map<String, Object?>>[];
  final favorites = <Map<String, Object?>>[];
  final wrong = <Map<String, Object?>>[];
  final ai = <Map<String, Object?>>[];
  var recordId = 100;
  for (var b = 1; b <= banks; b++) {
    final bankId = 'bank-$b';
    bankList.add({
      'id': bankId,
      'name': 'Synthetic Bank $b',
      'createdAt': 1000 * b,
      'updatedAt': 2000 * b,
      'questionCount': questionsPerBank,
    });
    questions[bankId] = [];
    for (var i = 1; i <= questionsPerBank; i++) {
      final q = Question(
        id: 'b$b-q$i',
        bankId: bankId,
        type: QuestionType.single,
        question: 'Synthetic question $b-$i?',
        options: const {'A': 'Alpha', 'B': 'Beta'},
        answer: const ['A'],
        tags: const [],
      );
      questions[bankId]!.add((withHashes ? attachQuestionHash(q) : q).toJson());
      if (withRecords) {
        records.add({
          'id': recordId++,
          'bankId': bankId,
          'questionId': q.id,
          'userAnswer': i.isEven ? ['B'] : ['A'],
          'status': i.isEven ? 'wrong' : 'correct',
          'timestamp': 5000 + i,
        });
      }
      if (i == 1) {
        favorites.add({
          'id': b,
          'bankId': bankId,
          'questionId': q.id,
          'timestamp': 6000,
        });
      }
      if (withWrong && i.isEven) {
        wrong.add({
          'id': b,
          'bankId': bankId,
          'questionId': q.id,
          'firstWrongAt': 5000 + i,
          'lastWrongAt': 5000 + i,
          'wrongCount': 2,
          'lastRecordId': recordId - 1,
        });
      }
      if (withAi && i == 1) {
        ai.add({
          'id': b,
          'bankId': bankId,
          'questionId': q.id,
          'explanation': 'Synthetic explanation',
          'model': 'test-model',
          'createdAt': 7000,
        });
      }
    }
  }
  return {
    'version': version,
    'exportedAt': 1700000000000,
    'banks': bankList,
    'questions': questions,
    'records': records,
    'favorites': favorites,
    if (version >= 2 && withAi) 'aiExplanations': ai,
    if (version >= 2 && withSettings)
      'settings': [
        {'key': 'theme', 'value': 'dark', 'updatedAt': 1},
        {'key': 'ai_apiKey', 'value': 'sk-NOT-A-REAL-KEY', 'updatedAt': 1},
        {
          'key': 'ai_endpoint',
          'value': 'https://example.invalid/v1',
          'updatedAt': 1,
        },
        {'key': 'ai_model', 'value': 'model-x', 'updatedAt': 1},
      ],
    if (version >= 3 && withWrong) 'wrongQuestions': wrong,
  };
}
