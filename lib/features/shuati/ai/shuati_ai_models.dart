/// 刷题助手 AI 服务的类型：LLM 调用抽象、生成结果、答案补全补丁。
///
/// [ShuatiAiLlmRunner] 是对 `lib/core/ai`（LlmClient / LlmConfigController）的
/// 最小抽象：服务层只依赖这一接口，UI / 装配层提供真实适配器，单测注入 fake。
library;

import 'dart:convert';

import '../domain/shuati_models.dart';

/// 一次 LLM 请求（纯文本提示词；按题场景不需要多轮消息）。
class ShuatiAiRequest {
  const ShuatiAiRequest({required this.prompt, this.maxTokens});

  /// 已组装好的中文提示词。
  final String prompt;

  /// 输出长度上限提示（由适配器映射到具体参数；`null` 用默认）。
  final int? maxTokens;
}

/// 一次 LLM 响应。
class ShuatiAiCompletion {
  const ShuatiAiCompletion({required this.text, required this.model});

  /// 模型原始输出文本（可能是 JSON、带围栏的 JSON 或纯文本）。
  final String text;

  /// 实际生效的模型名（写入 `ai_explanations.model`）。
  final String model;
}

/// LLM 调用抽象：向当前生效的模型发一次补全请求。
///
/// 适配器负责端点 / 密钥 / 重试 / 超时；实现方失败时应抛异常，
/// 由服务层统一包成 [ShuatiAiFailure]。
abstract class ShuatiAiLlmRunner {
  Future<ShuatiAiCompletion> complete(ShuatiAiRequest request);
}

/// AI 调用失败（网络 / 鉴权 / 超时 / 空响应），面向用户的中文说明。
class ShuatiAiFailure implements Exception {
  const ShuatiAiFailure(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'ShuatiAiFailure: $message';
}

/// 一道题的 AI 解析结果（结构化）。
class AiExplanation {
  const AiExplanation({
    required this.explanation,
    this.optionExplanations,
    this.model,
    this.fromCache = false,
  });

  /// 整题解析文本；JSON 解析失败时降级为模型原文。
  final String explanation;

  /// `{A: "...", true: "..."}` 逐选项解析（判断题键为 `true` / `false`）。
  final Map<String, String>? optionExplanations;

  /// 生成它的模型名。
  final String? model;

  /// 是否命中本地缓存（`ai_explanations` 表）。
  final bool fromCache;

  /// 序列化为写入 `ai_explanations.explanation` 的存储文本。
  String toStorage() {
    final opts = optionExplanations;
    if (opts == null || opts.isEmpty) return explanation;
    return _encodeJson({
      'explanation': explanation,
      'optionExplanations': opts,
    });
  }

  /// 从缓存文本还原：`{...}` JSON 解码失败时整体作为解析文本（向后兼容纯文本缓存）。
  static AiExplanation fromStorage(String text, {String? model}) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{')) {
      final decoded = _decodeJson(trimmed);
      if (decoded is Map) {
        final explanation = decoded['explanation'];
        final opts = decoded['optionExplanations'];
        return AiExplanation(
          explanation: explanation is String ? explanation : text,
          optionExplanations: _stringMap(opts),
          model: model,
          fromCache: true,
        );
      }
    }
    return AiExplanation(explanation: text, model: model, fromCache: true);
  }
}

/// AI 对一道「缺答案题」的建议补丁（预览页勾选后才生效，绝不静默覆盖原答案）。
class AiQuestionPatch {
  const AiQuestionPatch({this.answer, this.explanation});

  /// 建议答案（已按题型规范化：选择题大写字母、判断题 `true` / `false`）。
  final List<String>? answer;

  /// 建议的简短解析。
  final String? explanation;

  /// 是否有任何可用内容。
  bool get isEmpty =>
      (answer == null || answer!.isEmpty) &&
      (explanation == null || explanation!.isEmpty);
}

/// 给全局 AI 追问面板用的结构化题目上下文（不含内部 id）。
String buildShuatiQuestionContext(Question question, {String? userAnswer}) {
  final buf = StringBuffer()
    ..writeln('【刷题助手 · 题目上下文】')
    ..writeln('题型：${question.type.label}')
    ..writeln('题干：${question.question}');
  final options = question.options;
  if (options != null && options.isNotEmpty) {
    buf.writeln('选项：');
    for (final e in options.entries) {
      buf.writeln('  ${e.key}. ${e.value}');
    }
  }
  buf.writeln('参考答案：${formatShuatiAnswer(question)}');
  if (userAnswer != null && userAnswer.trim().isNotEmpty) {
    buf.writeln('我的作答：${userAnswer.trim()}');
  }
  final explanation = question.explanation;
  if (explanation != null && explanation.trim().isNotEmpty) {
    buf.writeln('已有解析：${explanation.trim()}');
  }
  buf.writeln('请基于以上内容回答我的追问。');
  return buf.toString();
}

/// 把 `Question.answer` 转成展示文本：判断题 → 对 / 错，其余原样拼接。
String formatShuatiAnswer(Question question) {
  if (question.answer.isEmpty) return '（暂无答案）';
  if (question.type == QuestionType.judge) {
    return question.answer.first == 'true' ? '对' : '错';
  }
  return question.answer.join('、');
}

Map<String, String>? _stringMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, String>{};
  for (final e in value.entries) {
    final key = e.key;
    final v = e.value;
    if (key is String && v is String && v.trim().isNotEmpty) {
      result[key] = v.trim();
    }
  }
  return result.isEmpty ? null : result;
}

Object? _decodeJson(String text) {
  try {
    return const JsonDecoder().convert(text);
  } on Object {
    return null;
  }
}

String _encodeJson(Object? value) => const JsonEncoder().convert(value);
