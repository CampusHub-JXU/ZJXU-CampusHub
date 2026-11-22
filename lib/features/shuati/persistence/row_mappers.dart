/// 领域对象 ⇄ SQLite 行。JSON 列统一用 `jsonEncode` / `jsonDecode`，
/// 解码失败的坏行退化为「空值」而不是抛出（读路径永不因单行损坏崩溃）。
library;

import 'dart:convert';

import '../domain/shuati_models.dart';

Object? _decode(Object? raw) {
  if (raw is! String) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

String encodeJson(Object? value) => jsonEncode(value);

List<String> _stringList(Object? decoded) {
  if (decoded is! List) return const [];
  return [
    for (final item in decoded)
      if (item is String) item,
  ];
}

Map<String, String>? _stringMap(Object? decoded) {
  if (decoded is! Map) return null;
  return {
    for (final e in decoded.entries)
      if (e.key is String && e.value is String)
        e.key as String: e.value as String,
  };
}

// ---- banks ----

Map<String, Object?> bankToRow(QuestionBank b) => {
  'id': b.id,
  'name': b.name,
  'description': b.description,
  'created_at': b.createdAt,
  'updated_at': b.updatedAt,
  'question_count': b.questionCount,
  'source_file_name': b.sourceFileName,
  'source_file_ext': b.sourceFileExt,
};

QuestionBank bankFromRow(Map<String, Object?> r) => QuestionBank(
  id: r['id']! as String,
  name: r['name']! as String,
  description: r['description'] as String?,
  createdAt: r['created_at']! as int,
  updatedAt: r['updated_at']! as int,
  questionCount: r['question_count']! as int,
  sourceFileName: r['source_file_name'] as String?,
  sourceFileExt: r['source_file_ext'] as String?,
);

// ---- questions ----

Map<String, Object?> questionToRow(Question q, {required int sortOrder}) => {
  'id': q.id,
  'bank_id': q.bankId,
  'type': q.type.name,
  'question': q.question,
  'options_json': q.options == null ? null : encodeJson(q.options),
  'answer_json': encodeJson(q.answer),
  'explanation': q.explanation,
  'option_explanations_json': q.optionExplanations == null
      ? null
      : encodeJson(q.optionExplanations),
  'tags_json': q.tags == null ? null : encodeJson(q.tags),
  'content_hash': q.contentHash,
  'answer_hash': q.answerHash,
  'sort_order': sortOrder,
};

Question questionFromRow(Map<String, Object?> r) => Question(
  id: r['id']! as String,
  bankId: r['bank_id']! as String,
  type: QuestionType.tryParse(r['type']) ?? QuestionType.short,
  question: r['question']! as String,
  options: _stringMap(_decode(r['options_json'])),
  answer: _stringList(_decode(r['answer_json'])),
  explanation: r['explanation'] as String?,
  optionExplanations: _stringMap(_decode(r['option_explanations_json'])),
  tags: r['tags_json'] == null ? null : _stringList(_decode(r['tags_json'])),
  contentHash: r['content_hash'] as String?,
  answerHash: r['answer_hash'] as String?,
);

// ---- records ----

Map<String, Object?> recordToRow(PracticeRecord r) => {
  if (r.id != null) 'id': r.id,
  'bank_id': r.bankId,
  'question_id': r.questionId,
  'user_answer_json': encodeJson(r.userAnswer),
  'status': r.status.name,
  'timestamp': r.timestamp,
};

PracticeRecord recordFromRow(Map<String, Object?> r) => PracticeRecord(
  id: r['id']! as int,
  bankId: r['bank_id']! as String,
  questionId: r['question_id']! as String,
  userAnswer: _stringList(_decode(r['user_answer_json'])),
  status: AnswerStatus.tryParse(r['status']) ?? AnswerStatus.unanswered,
  timestamp: r['timestamp']! as int,
);

// ---- favorites ----

Map<String, Object?> favoriteToRow(Favorite f) => {
  if (f.id != null) 'id': f.id,
  'bank_id': f.bankId,
  'question_id': f.questionId,
  'timestamp': f.timestamp,
};

Favorite favoriteFromRow(Map<String, Object?> r) => Favorite(
  id: r['id']! as int,
  bankId: r['bank_id']! as String,
  questionId: r['question_id']! as String,
  timestamp: r['timestamp']! as int,
);

// ---- wrong questions ----

Map<String, Object?> wrongToRow(PermanentWrongQuestion w) => {
  if (w.id != null) 'id': w.id,
  'bank_id': w.bankId,
  'question_id': w.questionId,
  'first_wrong_at': w.firstWrongAt,
  'last_wrong_at': w.lastWrongAt,
  'wrong_count': w.wrongCount,
  'last_record_id': w.lastRecordId,
};

PermanentWrongQuestion wrongFromRow(Map<String, Object?> r) =>
    PermanentWrongQuestion(
      id: r['id']! as int,
      bankId: r['bank_id']! as String,
      questionId: r['question_id']! as String,
      firstWrongAt: r['first_wrong_at']! as int,
      lastWrongAt: r['last_wrong_at']! as int,
      wrongCount: r['wrong_count']! as int,
      lastRecordId: r['last_record_id'] as int?,
    );

// ---- ai explanations (opaque) ----

Map<String, Object?> aiToRow(AiExplanationRow a) => {
  if (a.id != null) 'id': a.id,
  'bank_id': a.bankId,
  'question_id': a.questionId,
  'explanation': a.explanation,
  'model': a.model,
  'created_at': a.createdAt,
};

AiExplanationRow aiFromRow(Map<String, Object?> r) => AiExplanationRow(
  id: r['id']! as int,
  bankId: r['bank_id']! as String,
  questionId: r['question_id']! as String,
  explanation: r['explanation']! as String,
  model: r['model'] as String?,
  createdAt: r['created_at']! as int,
);

// ---- settings ----

Map<String, Object?> settingToRow(AppSetting s) => {
  'key': s.key,
  'value_json': encodeJson(s.value),
  'updated_at': s.updatedAt,
};

AppSetting settingFromRow(Map<String, Object?> r) => AppSetting(
  key: r['key']! as String,
  value: _decode(r['value_json']),
  updatedAt: r['updated_at']! as int,
);

// ---- sessions ----

Map<String, Object?> sessionToRow(PracticeSessionRecord s) => {
  'id': s.id,
  'bank_id': s.bankId,
  'mode': s.mode.name,
  'type_filter': s.typeFilter?.name,
  'current_index': s.currentIndex,
  'question_ids_json': encodeJson(s.questionIds),
  'updated_at': s.updatedAt,
};

PracticeSessionRecord? sessionFromRow(Map<String, Object?> r) {
  final mode = PracticeMode.tryParse(r['mode']);
  if (mode == null) return null;
  return PracticeSessionRecord(
    id: r['id']! as String,
    bankId: r['bank_id']! as String,
    mode: mode,
    typeFilter: QuestionType.tryParse(r['type_filter']),
    currentIndex: r['current_index']! as int,
    questionIds: _stringList(_decode(r['question_ids_json'])),
    updatedAt: r['updated_at']! as int,
  );
}
