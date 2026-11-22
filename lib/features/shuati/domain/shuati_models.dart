/// 刷题助手领域模型（纯 Dart，无 IO / 无 Flutter 依赖）。
///
/// 字段与 PWA `src/types/index.ts` 逐一对应，`toJson` / `fromJson` 与 PWA 的
/// `ExportDataV3` 条目同形，因此备份导入导出可以直接复用。
library;

import 'js_compat.dart';

// ============ 枚举 ============

/// PWA `QuestionType`。`name` 即线上（备份 JSON / DB）取值。
enum QuestionType {
  single('单选'),
  multiple('多选'),
  judge('判断'),
  blank('填空'),
  short('简答');

  const QuestionType(this.label);

  /// 中文标签（PWA `getQuestionTypeLabel`）。
  final String label;

  /// 严格匹配（区分大小写、不认别名）。PWA 的 `isQuestionType` 同样严格：
  /// `fill` / `text` 等旧别名**不是**合法类型，会落到题型推断。
  static QuestionType? tryParse(Object? value) {
    if (value is! String) return null;
    for (final type in QuestionType.values) {
      if (type.name == value) return type;
    }
    return null;
  }

  /// 填空 / 简答：展示答案后由用户自评对错（非考试模式）。
  bool get isSelfGraded => this == blank || this == short;

  /// 选择题（需要选项）。
  bool get isChoice => this == single || this == multiple;
}

/// PWA `AnswerStatus`。
enum AnswerStatus {
  correct,
  wrong,
  unanswered;

  static AnswerStatus? tryParse(Object? value) {
    if (value is! String) return null;
    for (final status in AnswerStatus.values) {
      if (status.name == value) return status;
    }
    return null;
  }

  /// 是否「有效作答」（正确 / 错误）。
  bool get isDecided => this == correct || this == wrong;
}

/// PWA `PracticeMode`。
enum PracticeMode {
  sequential('顺序练习'),
  random('随机练习'),
  wrong('错题本'),
  favorite('收藏题目'),
  exam('模拟考试');

  const PracticeMode(this.label);

  /// PWA `MODE_LABELS`。
  final String label;

  static PracticeMode? tryParse(Object? value) {
    if (value is! String) return null;
    for (final mode in PracticeMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

// ============ JSON 取值辅助 ============

/// 把 JSON 标量转成字符串（对齐 JS `String(x)` 对标量的结果）；
/// `null` / 容器类型返回 `null`（调用方丢弃）。
String? jsonScalarToString(Object? value) {
  if (value is String) return value;
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) return jsNumberToString(value);
  return null;
}

/// 接受 int 或整数值的 double。
int? jsonInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

String? _optString(Object? value) => value is String ? value : null;

Map<String, String>? _stringMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key;
    final text = jsonScalarToString(entry.value);
    if (key is String && text != null) result[key] = text;
  }
  return result;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  final result = <String>[];
  for (final item in value) {
    final text = jsonScalarToString(item);
    if (text != null) result.add(text);
  }
  return result;
}

// ============ 题目 ============

/// PWA `Question`。
class Question {
  const Question({
    required this.id,
    required this.bankId,
    required this.type,
    required this.question,
    required this.answer,
    this.options,
    this.explanation,
    this.optionExplanations,
    this.tags,
    this.contentHash,
    this.answerHash,
  });

  final String id;
  final String bankId;
  final QuestionType type;
  final String question;

  /// `{A: "xxx", B: "yyy"}`；判断 / 填空 / 简答通常为 `null`。
  final Map<String, String>? options;

  /// `["B"]` / `["A","C"]` / `["true"]` / 填空文本。
  final List<String> answer;
  final String? explanation;

  /// `{A: "选项 A 为什么对/错", true: "判断题正确项解析"}`。
  final Map<String, String>? optionExplanations;
  final List<String>? tags;
  final String? contentHash;
  final String? answerHash;

  /// 能否作答：有答案，且选择题至少有一个非空选项（PWA `QuestionCard.isQuestionReady`）。
  bool get isPracticeReady {
    if (answer.isEmpty) return false;
    if (!type.isChoice) return true;
    return options?.values.any((v) => jsTrim(v).isNotEmpty) ?? false;
  }

  Question copyWith({
    String? id,
    String? bankId,
    QuestionType? type,
    String? question,
    List<String>? answer,
    Map<String, String>? options,
    String? explanation,
    Map<String, String>? optionExplanations,
    List<String>? tags,
    String? contentHash,
    String? answerHash,
  }) {
    return Question(
      id: id ?? this.id,
      bankId: bankId ?? this.bankId,
      type: type ?? this.type,
      question: question ?? this.question,
      answer: answer ?? this.answer,
      options: options ?? this.options,
      explanation: explanation ?? this.explanation,
      optionExplanations: optionExplanations ?? this.optionExplanations,
      tags: tags ?? this.tags,
      contentHash: contentHash ?? this.contentHash,
      answerHash: answerHash ?? this.answerHash,
    );
  }

  /// 与 PWA `JSON.stringify` 同形：值为 `null`（JS `undefined`）的字段省略。
  Map<String, Object?> toJson() => {
    'id': id,
    'bankId': bankId,
    'type': type.name,
    'question': question,
    if (options != null) 'options': options,
    'answer': answer,
    if (explanation != null) 'explanation': explanation,
    if (optionExplanations != null) 'optionExplanations': optionExplanations,
    if (tags != null) 'tags': tags,
    if (contentHash != null) 'contentHash': contentHash,
    if (answerHash != null) 'answerHash': answerHash,
  };

  /// 宽松解析一条备份 / DB 题目；缺 `id` / `bankId` / `question` / 合法 `type`
  /// 时返回 `null`（由调用方决定是否先补全 type）。
  static Question? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = _optString(json['id']);
    final bankId = _optString(json['bankId']);
    final text = _optString(json['question']);
    final type = QuestionType.tryParse(json['type']);
    if (id == null ||
        id.isEmpty ||
        bankId == null ||
        bankId.isEmpty ||
        text == null ||
        type == null) {
      return null;
    }
    return Question(
      id: id,
      bankId: bankId,
      type: type,
      question: text,
      options: _stringMap(json['options']),
      answer: _stringList(json['answer']),
      explanation: _optString(json['explanation']),
      optionExplanations: _stringMap(json['optionExplanations']),
      tags: json['tags'] is List ? _stringList(json['tags']) : null,
      contentHash: _optString(json['contentHash']),
      answerHash: _optString(json['answerHash']),
    );
  }
}

// ============ 题库 ============

/// PWA `QuestionBank`。
class QuestionBank {
  const QuestionBank({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.questionCount,
    this.description,
    this.sourceFileName,
    this.sourceFileExt,
  });

  final String id;
  final String name;
  final String? description;
  final int createdAt;
  final int updatedAt;
  final int questionCount;
  final String? sourceFileName;
  final String? sourceFileExt;

  QuestionBank copyWith({
    String? name,
    String? description,
    int? updatedAt,
    int? questionCount,
  }) {
    return QuestionBank(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      questionCount: questionCount ?? this.questionCount,
      sourceFileName: sourceFileName,
      sourceFileExt: sourceFileExt,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'questionCount': questionCount,
    if (sourceFileName != null) 'sourceFileName': sourceFileName,
    if (sourceFileExt != null) 'sourceFileExt': sourceFileExt,
  };

  static QuestionBank? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = _optString(json['id']);
    if (id == null || id.isEmpty) return null;
    final createdAt = jsonInt(json['createdAt']) ?? 0;
    return QuestionBank(
      id: id,
      name: _optString(json['name']) ?? '',
      description: _optString(json['description']),
      createdAt: createdAt,
      updatedAt: jsonInt(json['updatedAt']) ?? createdAt,
      questionCount: jsonInt(json['questionCount']) ?? 0,
      sourceFileName: _optString(json['sourceFileName']),
      sourceFileExt: _optString(json['sourceFileExt']),
    );
  }
}

// ============ 做题记录 ============

/// PWA `PracticeRecord`。`id` 在 PWA 是 IndexedDB 自增键，新记录为 `null`。
class PracticeRecord {
  const PracticeRecord({
    required this.bankId,
    required this.questionId,
    required this.userAnswer,
    required this.status,
    required this.timestamp,
    this.id,
  });

  final int? id;
  final String bankId;
  final String questionId;
  final List<String> userAnswer;
  final AnswerStatus status;
  final int timestamp;

  PracticeRecord copyWith({
    int? id,
    List<String>? userAnswer,
    AnswerStatus? status,
    int? timestamp,
  }) {
    return PracticeRecord(
      id: id ?? this.id,
      bankId: bankId,
      questionId: questionId,
      userAnswer: userAnswer ?? this.userAnswer,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'bankId': bankId,
    'questionId': questionId,
    'userAnswer': userAnswer,
    'status': status.name,
    'timestamp': timestamp,
  };

  static PracticeRecord? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final bankId = _optString(json['bankId']);
    final questionId = _optString(json['questionId']);
    final status = AnswerStatus.tryParse(json['status']);
    final timestamp = jsonInt(json['timestamp']);
    if (bankId == null ||
        bankId.isEmpty ||
        questionId == null ||
        questionId.isEmpty ||
        status == null ||
        timestamp == null) {
      return null;
    }
    return PracticeRecord(
      id: jsonInt(json['id']),
      bankId: bankId,
      questionId: questionId,
      userAnswer: _stringList(json['userAnswer']),
      status: status,
      timestamp: timestamp,
    );
  }
}

// ============ 永久错题本 ============

/// PWA `PermanentWrongQuestion`。
class PermanentWrongQuestion {
  const PermanentWrongQuestion({
    required this.bankId,
    required this.questionId,
    required this.firstWrongAt,
    required this.lastWrongAt,
    required this.wrongCount,
    this.id,
    this.lastRecordId,
  });

  final int? id;
  final String bankId;
  final String questionId;
  final int firstWrongAt;
  final int lastWrongAt;
  final int wrongCount;
  final int? lastRecordId;

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'bankId': bankId,
    'questionId': questionId,
    'firstWrongAt': firstWrongAt,
    'lastWrongAt': lastWrongAt,
    'wrongCount': wrongCount,
    if (lastRecordId != null) 'lastRecordId': lastRecordId,
  };

  static PermanentWrongQuestion? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final bankId = _optString(json['bankId']);
    final questionId = _optString(json['questionId']);
    final first = jsonInt(json['firstWrongAt']);
    final last = jsonInt(json['lastWrongAt']);
    if (bankId == null ||
        bankId.isEmpty ||
        questionId == null ||
        questionId.isEmpty ||
        first == null ||
        last == null) {
      return null;
    }
    return PermanentWrongQuestion(
      id: jsonInt(json['id']),
      bankId: bankId,
      questionId: questionId,
      firstWrongAt: first,
      lastWrongAt: last,
      wrongCount: jsonInt(json['wrongCount']) ?? 1,
      lastRecordId: jsonInt(json['lastRecordId']),
    );
  }
}

// ============ 收藏 ============

/// PWA `Favorite`。
class Favorite {
  const Favorite({
    required this.bankId,
    required this.questionId,
    required this.timestamp,
    this.id,
  });

  final int? id;
  final String bankId;
  final String questionId;
  final int timestamp;

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'bankId': bankId,
    'questionId': questionId,
    'timestamp': timestamp,
  };

  static Favorite? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final bankId = _optString(json['bankId']);
    final questionId = _optString(json['questionId']);
    final timestamp = jsonInt(json['timestamp']);
    if (bankId == null ||
        bankId.isEmpty ||
        questionId == null ||
        questionId.isEmpty ||
        timestamp == null) {
      return null;
    }
    return Favorite(
      id: jsonInt(json['id']),
      bankId: bankId,
      questionId: questionId,
      timestamp: timestamp,
    );
  }
}

// ============ AI 解析（不透明缓存行） ============

/// PWA `AIExplanation`：模型生成的解析文本缓存。
///
/// 原生本阶段**不生成** AI 解析，只把备份里的行不透明地保存 / 回导出，
/// 以便与 PWA 备份往返。**不含**任何端点 / 密钥。
class AiExplanationRow {
  const AiExplanationRow({
    required this.bankId,
    required this.questionId,
    required this.explanation,
    required this.createdAt,
    this.id,
    this.model,
  });

  final int? id;
  final String bankId;
  final String questionId;
  final String explanation;
  final String? model;
  final int createdAt;

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'bankId': bankId,
    'questionId': questionId,
    'explanation': explanation,
    if (model != null) 'model': model,
    'createdAt': createdAt,
  };

  static AiExplanationRow? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final questionId = _optString(json['questionId']);
    final explanation = _optString(json['explanation']);
    if (questionId == null || questionId.isEmpty || explanation == null) {
      return null;
    }
    return AiExplanationRow(
      id: jsonInt(json['id']),
      // PWA v4 迁移之前的行可能没有 bankId（空串）；导入时按题目回填。
      bankId: _optString(json['bankId']) ?? '',
      questionId: questionId,
      explanation: explanation,
      model: _optString(json['model']),
      createdAt: jsonInt(json['createdAt']) ?? 0,
    );
  }
}

// ============ 设置 ============

/// PWA `AppSetting`（`value` 为任意 JSON）。
class AppSetting {
  const AppSetting({
    required this.key,
    required this.value,
    required this.updatedAt,
  });

  final String key;
  final Object? value;
  final int updatedAt;

  Map<String, Object?> toJson() => {
    'key': key,
    'value': value,
    'updatedAt': updatedAt,
  };

  static AppSetting? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final key = _optString(json['key']);
    if (key == null || key.isEmpty) return null;
    return AppSetting(
      key: key,
      value: json['value'],
      updatedAt: jsonInt(json['updatedAt']) ?? 0,
    );
  }
}

// ============ 练习会话（断点续练） ============

/// PWA `PracticeSessionRecord`。`id` 为 `last` 或 `${bankId}:${mode}:${typeFilter|all}`。
class PracticeSessionRecord {
  const PracticeSessionRecord({
    required this.id,
    required this.bankId,
    required this.mode,
    required this.currentIndex,
    required this.questionIds,
    required this.updatedAt,
    this.typeFilter,
  });

  final String id;
  final String bankId;
  final PracticeMode mode;
  final QuestionType? typeFilter;
  final int currentIndex;
  final List<String> questionIds;
  final int updatedAt;
}
