/// 旧版「刷题助手」PWA 备份的纯 Dart 结构检查 / 统计（迁移 Stage A）。
///
/// 只读 JSON，不写库 / 不迁移 / 不发网络 / 不落盘；只接受 PWA `importFullBackup`
/// 承认的版本（1/2/3，缺省按 `data.version ?? 1` 视为 1），其余 fail closed。
/// 证据（源代码，非猜测）见 `docs/shuati-native-draft.md`。
library;

import 'dart:convert';

/// 单条校验发现。[code] 便于测试断言，[message] 面向人阅读。
class ShuatiBackupIssue {
  const ShuatiBackupIssue(this.code, this.message, {this.detail});

  final ShuatiBackupIssueCode code;
  final String message;
  final String? detail;
}

/// 校验发现分类。
enum ShuatiBackupIssueCode {
  malformedEntry,
  missingBankId,
  duplicateBankId,
  unknownBankId,
  missingQuestionId,
  duplicateQuestionId,
  unknownQuestionType,
  missingAnswer,
}

/// 备份检查结果。`errorMessage != null` 表示无法安全读取（fail closed），
/// 此时所有计数为 0 且 [issues] 为空。
class ShuatiBackupInspection {
  const ShuatiBackupInspection({
    required this.version,
    required this.bankCount,
    required this.questionCount,
    required this.recordCount,
    required this.favoriteCount,
    required this.aiExplanationCount,
    required this.settingCount,
    required this.ignoredAiSettingCount,
    required this.wrongQuestionCount,
    required this.issues,
    this.errorMessage,
  });

  const ShuatiBackupInspection.failure(this.errorMessage)
    : version = null,
      bankCount = 0,
      questionCount = 0,
      recordCount = 0,
      favoriteCount = 0,
      aiExplanationCount = 0,
      settingCount = 0,
      ignoredAiSettingCount = 0,
      wrongQuestionCount = 0,
      issues = const [];

  final int? version;
  final int bankCount;
  final int questionCount;
  final int recordCount;
  final int favoriteCount;
  final int aiExplanationCount;

  /// `settings` 条目总数（含将被忽略的 AI 设置）。
  final int settingCount;

  /// key 以 `ai_` 开头、原 PWA 恢复时会丢弃的设置条数。
  final int ignoredAiSettingCount;

  final int wrongQuestionCount;
  final List<ShuatiBackupIssue> issues;

  /// 无法安全读取的原因；`null` 表示结构可读。
  final String? errorMessage;

  bool get isSupported => errorMessage == null;
}

/// 备份 schema 常量与检查入口。
abstract final class ShuatiBackupSchema {
  /// PWA `importFullBackup` 唯一承认的版本集合。
  static const Set<int> supportedVersions = {1, 2, 3};

  /// PWA `types/index.ts` 的 `QuestionType`。
  static const Set<String> questionTypes = {
    'single',
    'multiple',
    'judge',
    'blank',
    'short',
  };

  /// 原 PWA 恢复整库时丢弃的 AI 设置 key 前缀。
  static const String aiSettingKeyPrefix = 'ai_';

  /// 解析并检查备份 JSON 文本。
  static ShuatiBackupInspection inspectJson(String jsonText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (error) {
      return ShuatiBackupInspection.failure('备份不是合法 JSON：${error.message}');
    }
    return inspect(decoded);
  }

  /// 检查已解析的备份对象（可为 `null`）。
  static ShuatiBackupInspection inspect(Object? decoded) {
    if (decoded is! Map) {
      return const ShuatiBackupInspection.failure('备份根节点必须是 JSON 对象');
    }
    try {
      return _inspectMap(Map<String, Object?>.from(decoded));
    } on _InvalidBackup catch (error) {
      return ShuatiBackupInspection.failure(error.message);
    }
  }

  static ShuatiBackupInspection _inspectMap(Map<String, Object?> map) {
    final versionValue = map['version'] ?? 1;
    if (versionValue is! int || !supportedVersions.contains(versionValue)) {
      throw _InvalidBackup('不支持的备份版本：$versionValue');
    }

    final questions = map['questions'] ?? const <String, Object?>{};
    if (questions is! Map) {
      throw const _InvalidBackup('备份字段 questions 必须是对象');
    }

    final issues = <ShuatiBackupIssue>[];
    final banks = _readList(map, 'banks');
    final bankIds = <String>{};
    for (final entry in banks) {
      if (entry is! Map) {
        issues.add(
          const ShuatiBackupIssue(
            ShuatiBackupIssueCode.malformedEntry,
            '题库条目不是对象，已忽略',
          ),
        );
        continue;
      }
      final id = entry['id'];
      if (id is! String || id.isEmpty) {
        issues.add(
          const ShuatiBackupIssue(
            ShuatiBackupIssueCode.missingBankId,
            '题库缺少 id',
          ),
        );
      } else if (!bankIds.add(id)) {
        issues.add(
          ShuatiBackupIssue(
            ShuatiBackupIssueCode.duplicateBankId,
            '题库 id 重复',
            detail: id,
          ),
        );
      }
    }

    var questionCount = 0;
    final questionIds = <String>{};
    for (final bucket in questions.entries) {
      final items = bucket.value;
      if (items is! List) {
        issues.add(
          ShuatiBackupIssue(
            ShuatiBackupIssueCode.malformedEntry,
            '题库题目列表不是数组',
            detail: '${bucket.key}',
          ),
        );
        continue;
      }
      for (final item in items) {
        questionCount++;
        if (item is! Map) {
          issues.add(
            const ShuatiBackupIssue(
              ShuatiBackupIssueCode.malformedEntry,
              '题目条目不是对象，已忽略',
            ),
          );
          continue;
        }
        _inspectQuestion(item, bankIds, questionIds, issues);
      }
    }

    final records = _readList(map, 'records');
    final favorites = _readList(map, 'favorites');
    final aiExplanations = _readList(map, 'aiExplanations');
    final wrongQuestions = _readList(map, 'wrongQuestions');
    final settings = _readList(map, 'settings');

    return ShuatiBackupInspection(
      version: versionValue,
      bankCount: banks.length,
      questionCount: questionCount,
      recordCount: records.length,
      favoriteCount: favorites.length,
      aiExplanationCount: aiExplanations.length,
      settingCount: settings.length,
      ignoredAiSettingCount: settings.where(_isAiSetting).length,
      wrongQuestionCount: wrongQuestions.length,
      issues: issues,
    );
  }

  static void _inspectQuestion(
    Map<dynamic, dynamic> item,
    Set<String> bankIds,
    Set<String> questionIds,
    List<ShuatiBackupIssue> issues,
  ) {
    final id = item['id'];
    final questionId = id is String && id.isNotEmpty ? id : null;
    if (questionId == null) {
      issues.add(
        const ShuatiBackupIssue(
          ShuatiBackupIssueCode.missingQuestionId,
          '题目缺少 id',
        ),
      );
    } else if (!questionIds.add(questionId)) {
      issues.add(
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.duplicateQuestionId,
          '题目 id 重复',
          detail: questionId,
        ),
      );
    }

    final bankId = item['bankId'];
    if (bankId is! String || bankId.isEmpty) {
      issues.add(
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.missingBankId,
          '题目缺少 bankId',
          detail: questionId,
        ),
      );
    } else if (bankIds.isNotEmpty && !bankIds.contains(bankId)) {
      issues.add(
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.unknownBankId,
          '题目 bankId 不在题库列表中',
          detail: bankId,
        ),
      );
    }

    final type = item['type'];
    if (type is! String || !questionTypes.contains(type)) {
      issues.add(
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.unknownQuestionType,
          '题目 type 未知',
          detail: '$type',
        ),
      );
    }

    final answer = item['answer'];
    if (answer is! List || answer.isEmpty) {
      issues.add(
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.missingAnswer,
          '题目缺少答案',
          detail: questionId,
        ),
      );
    }
  }

  static bool _isAiSetting(Object? setting) {
    if (setting is! Map) return false;
    final key = setting['key'];
    return key is String && key.startsWith(aiSettingKeyPrefix);
  }

  static List<Object?> _readList(Map<String, Object?> map, String field) {
    final value = map[field];
    if (value == null) return const [];
    if (value is List) return value;
    throw _InvalidBackup('备份字段 $field 必须是数组');
  }
}

class _InvalidBackup implements Exception {
  const _InvalidBackup(this.message);

  final String message;
}
