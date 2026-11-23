/// 刷题助手 AI 服务（Issue #117）：题目解析生成 / 缓存、导入缺答案题补全、
/// 追问上下文组装。
///
/// 只依赖 [ShuatiAiLlmRunner] 抽象 + [AiExplanationRepository]，不碰端点 / 密钥；
/// 装配层用 `lib/core/ai` 的 LlmClient 实现 runner，单测注入 fake。
library;

import 'dart:convert';

import '../../../core/logging/app_logger.dart';
import '../domain/js_compat.dart';
import '../domain/shuati_models.dart';
import '../persistence/activity_repositories.dart';
import 'shuati_ai_models.dart';

/// 缺答案题补全的每批题数上限。
const int kShuatiAiEnrichBatchSize = 8;

/// 解析生成提示词中选项解析键的合法前缀（A–Z）。
final RegExp _optionKey = RegExp(r'^[A-Za-z]$');

class ShuatiAiService {
  ShuatiAiService(
    this._explanations,
    this._runner, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AiExplanationRepository _explanations;
  final ShuatiAiLlmRunner _runner;
  final DateTime Function() _clock;

  /// 取某题的 AI 解析：非 [forceRefresh] 时先查 `ai_explanations` 缓存，
  /// 命中直接返回；否则调用 LLM 生成、写入缓存后返回。
  ///
  /// [bankId] 缺省取 `question.bankId`（缓存表外键需要）。
  /// LLM 返回非 JSON 时降级：整段文本作为 `explanation`。
  Future<AiExplanation> getOrGenerateExplanation({
    required Question question,
    String? bankId,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await _explanations.getCached(question.id);
      if (cached != null) {
        return AiExplanation.fromStorage(
          cached.explanation,
          model: cached.model,
        );
      }
    }

    final completion = await _complete(
      _explanationPrompt(question),
      maxTokens: 1200,
    );
    final result = _parseExplanation(completion.text, model: completion.model);

    final row = AiExplanationRow(
      bankId: bankId ?? question.bankId,
      questionId: question.id,
      explanation: result.toStorage(),
      model: completion.model,
      createdAt: _clock().millisecondsSinceEpoch,
    );
    try {
      await _explanations.upsertForQuestion(row);
    } on Object catch (e) {
      // 缓存写失败不影响把解析返回给用户（例如题库已被删除）。
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.storage,
        'AI 解析缓存写入失败：$e',
      );
    }
    return result;
  }

  /// 分批请求 AI 为缺答案题补全答案与简短解析。
  ///
  /// 返回 `原列表下标 → 建议补丁`：只含 [questions] 中 `answer` 为空的题
  /// （已有答案的题被跳过，绝不建议覆盖）；解析失败 / 无建议的批安静跳过。
  /// LLM 调用失败抛 [ShuatiAiFailure]。
  Future<Map<int, AiQuestionPatch>> enrichMissingAnswers({
    required List<Question> questions,
  }) async {
    final targets = <(int, Question)>[
      for (final (i, q) in questions.indexed)
        if (q.answer.isEmpty) (i, q),
    ];
    if (targets.isEmpty) return const {};

    final patches = <int, AiQuestionPatch>{};
    for (
      var start = 0;
      start < targets.length;
      start += kShuatiAiEnrichBatchSize
    ) {
      final end = start + kShuatiAiEnrichBatchSize > targets.length
          ? targets.length
          : start + kShuatiAiEnrichBatchSize;
      final batch = targets.sublist(start, end);
      final completion = await _complete(
        _enrichPrompt([for (final (_, q) in batch) q]),
        maxTokens: 2000,
      );
      final items = _parseEnrichResponse(completion.text);
      for (var i = 0; i < items.length && i < batch.length; i++) {
        final item = items[i];
        if (item == null) continue;
        final question = batch[i].$2;
        final patch = AiQuestionPatch(
          answer: _normalizeAiAnswer(item.answer, question),
          explanation: item.explanation,
        );
        if (!patch.isEmpty) patches[batch[i].$1] = patch;
      }
    }
    return patches;
  }

  /// 组装给全局 AI 追问面板的结构化题目上下文。
  String buildQuestionChatContext(Question question, {String? userAnswer}) =>
      buildShuatiQuestionContext(question, userAnswer: userAnswer);

  // ============ prompts ============

  String _explanationPrompt(Question q) {
    final buf = StringBuffer()
      ..writeln('你是一位严谨的题库解析助手。请为下面这道${q.type.label}题生成解析。')
      ..writeln()
      ..writeln(buildShuatiQuestionContext(q))
      ..writeln()
      ..writeln('要求：')
      ..writeln('1. 解析要精炼、直接说明为什么；不要复述题干，不要客套话。')
      ..writeln('2. 严格输出一个 JSON 对象，不要输出任何其它文字或 markdown 围栏：')
      ..writeln(
        '{"explanation": "整题解析", "optionExplanations": {"选项键": "该选项解析"}}',
      )
      ..writeln('3. optionExplanations 的键与选项字母一致（判断题用 "true"/"false"）；')
      ..writeln('   填空 / 简答题可以省略 optionExplanations 或给空对象。');
    return buf.toString();
  }

  String _enrichPrompt(List<Question> questions) {
    final buf = StringBuffer()
      ..writeln('你是一位严谨的题库补全助手。下面 ${questions.length} 道题缺少答案，')
      ..writeln('请给出每题的正确答案与一句简短解析。')
      ..writeln()
      ..writeln('严格输出一个 JSON 数组、长度 ${questions.length}、顺序与题目一致：')
      ..writeln('[{"answer": ..., "explanation": "..."}, ...]')
      ..writeln('answer 取值：选择题写字母（如 "A" 或 "AC"），判断题写 "对" 或 "错"，')
      ..writeln('填空 / 简答写答案文本。确实无法判断时该条给 null。')
      ..writeln('不要输出任何其它文字或 markdown 围栏。')
      ..writeln();
    for (final (i, q) in questions.indexed) {
      buf.writeln('--- 第 ${i + 1} 题 ---');
      buf.writeln(buildShuatiQuestionContext(q));
    }
    return buf.toString();
  }

  // ============ 响应解析 ============

  AiExplanation _parseExplanation(String text, {required String model}) {
    final json = _extractJson(text);
    if (json is Map) {
      final explanation = json['explanation'];
      return AiExplanation(
        explanation: explanation is String && explanation.trim().isNotEmpty
            ? explanation.trim()
            : jsTrim(text),
        optionExplanations: _parseOptionExplanations(
          json['optionExplanations'],
        ),
        model: model,
      );
    }
    // 降级：整段文本作为解析（PWA 也是宽松处理）。
    return AiExplanation(explanation: jsTrim(text), model: model);
  }

  Map<String, String>? _parseOptionExplanations(Object? value) {
    if (value is! Map) return null;
    final result = <String, String>{};
    for (final e in value.entries) {
      final key = e.key;
      final v = e.value;
      if (key is! String || v is! String) continue;
      final text = jsTrim(v);
      if (text.isEmpty) continue;
      final k = jsTrim(key);
      if (_optionKey.hasMatch(k)) {
        result[k.toUpperCase()] = text;
      } else if (k == 'true' || k == 'false' || k == '对' || k == '错') {
        result[k == 'true' || k == '对' ? 'true' : 'false'] = text;
      }
    }
    return result.isEmpty ? null : result;
  }

  List<_EnrichItem?> _parseEnrichResponse(String text) {
    final json = _extractJson(text, preferArray: true);
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (item is Map)
          _EnrichItem(
            answer: _rawAnswer(item['answer']),
            explanation: item['explanation'] is String
                ? jsTrim(item['explanation'] as String)
                : null,
          )
        else
          null,
    ];
  }

  /// `answer` 原始值 → 字符串列表（`"AC"` / `["A","C"]` / `"对"` / 文本）。
  List<String>? _rawAnswer(Object? value) {
    if (value is String) {
      final t = jsTrim(value);
      return t.isEmpty ? null : [t];
    }
    if (value is List) {
      final items = [
        for (final v in value)
          if (v is String && jsTrim(v).isNotEmpty) jsTrim(v),
      ];
      return items.isEmpty ? null : items;
    }
    if (value is num || value is bool) return ['$value'];
    return null;
  }

  /// 按题型规范化 AI 给的答案：选择题逐字母大写、判断题归一 `true` / `false`。
  List<String>? _normalizeAiAnswer(List<String>? raw, Question q) {
    if (raw == null) return null;
    switch (q.type) {
      case QuestionType.single || QuestionType.multiple:
        final letters = <String>[];
        for (final a in raw) {
          final compact = a.replaceAll(RegExp(r'[、，,\s]'), '');
          for (final ch in compact.split('')) {
            if (_optionKey.hasMatch(ch)) letters.add(ch.toUpperCase());
          }
        }
        final unique = letters.toSet().toList();
        return unique.isEmpty ? null : unique;
      case QuestionType.judge:
        for (final a in raw) {
          final t = jsTrim(a).toLowerCase();
          if (t == '对' || t == '正确' || t == 'true' || t == 't' || t == 'yes') {
            return const ['true'];
          }
          if (t == '错' || t == '错误' || t == 'false' || t == 'f' || t == 'no') {
            return const ['false'];
          }
        }
        return null;
      case QuestionType.blank || QuestionType.short:
        final items = [
          for (final a in raw)
            if (jsTrim(a).isNotEmpty) jsTrim(a),
        ];
        return items.isEmpty ? null : items;
    }
  }

  /// 从模型输出里抓第一个 JSON 对象 / 数组（容忍 ```json 围栏与前后噪声）。
  Object? _extractJson(String text, {bool preferArray = false}) {
    final trimmed = jsTrim(text);
    final open = preferArray ? '[' : '{';
    final close = preferArray ? ']' : '}';
    final start = trimmed.indexOf(open);
    final end = trimmed.lastIndexOf(close);
    if (start < 0 || end <= start) return null;
    try {
      return jsonDecode(trimmed.substring(start, end + 1));
    } on Object {
      return null;
    }
  }

  Future<ShuatiAiCompletion> _complete(String prompt, {int? maxTokens}) async {
    try {
      final c = await _runner.complete(
        ShuatiAiRequest(prompt: prompt, maxTokens: maxTokens),
      );
      if (jsTrim(c.text).isEmpty) {
        throw const ShuatiAiFailure('AI 返回了空内容，请稍后重试。');
      }
      return c;
    } on ShuatiAiFailure {
      rethrow;
    } on Object catch (e) {
      throw ShuatiAiFailure('AI 解析生成失败：$e', cause: e);
    }
  }
}

class _EnrichItem {
  const _EnrichItem({this.answer, this.explanation});

  final List<String>? answer;
  final String? explanation;
}
