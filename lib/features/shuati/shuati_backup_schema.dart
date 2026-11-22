/// 旧版「刷题助手」PWA 备份的纯 Dart 结构检查 / 统计（迁移 Stage A）。
///
/// 只读 JSON，不写库 / 不迁移 / 不发网络 / 不落盘；只接受 PWA `importFullBackup`
/// 承认的版本（1/2/3，缺省按 `data.version ?? 1` 视为 1），其余 fail closed。
/// 证据（源代码，非猜测）见 `docs/shuati-native-draft.md` 与 `docs/shuati-native-parity.md`。
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

  /// 原生**拒绝保存**的设置 key：AI 配置（端点 / 模型 / 密钥）与任何看起来像凭据的 key。
  ///
  /// 比 PWA 更严格（PWA 只丢 `ai_` 前缀）：除 `ai_` / `ai-` / `ai.` 前缀外，
  /// 含 `apikey` / `api_key` / `api-key` / `secret` / `token` / `password` 的 key
  /// 一律视为凭据。备份导入时丢弃并计数，设置仓库写入时直接抛错。
  static bool isAiOrSecretSettingKey(String key) {
    final k = key.toLowerCase();
    if (k.startsWith('ai_') || k.startsWith('ai-') || k.startsWith('ai.')) {
      return true;
    }
    return k.contains('apikey') ||
        k.contains('api_key') ||
        k.contains('api-key') ||
        k.contains('secret') ||
        k.contains('token') ||
        k.contains('password');
  }

  /// 单份 JSON 的 UTF-8 大小上限。
  static const int maxJsonBytes = 10 * 1024 * 1024;

  /// 每个集合的条目上限；`questions` 按所有题库桶合并计数。
  static const int maxEntriesPerCollection = 100000;

  /// 最多报告的问题数；若发现更多问题则整体拒绝备份。
  static const int maxIssuesReported = 100;

  /// 解析并检查备份 JSON 文本。
  static ShuatiBackupInspection inspectJson(String jsonText) {
    if (jsonText.length > maxJsonBytes) {
      return const ShuatiBackupInspection.failure('备份 JSON 超过大小上限');
    }
    if (utf8.encode(jsonText).length > maxJsonBytes) {
      return const ShuatiBackupInspection.failure('备份 JSON 超过大小上限');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (error) {
      return ShuatiBackupInspection.failure('备份不是合法 JSON：${error.message}');
    }
    return _inspectDecoded(decoded);
  }

  /// 检查已解析的备份对象（可为 `null`）。
  static ShuatiBackupInspection inspect(Object? decoded) {
    final int jsonBytes;
    try {
      jsonBytes = utf8.encode(jsonEncode(decoded)).length;
    } on Object {
      return const ShuatiBackupInspection.failure('备份对象无法编码为 JSON');
    }
    if (jsonBytes > maxJsonBytes) {
      return const ShuatiBackupInspection.failure('备份 JSON 超过大小上限');
    }
    return _inspectDecoded(decoded);
  }

  static ShuatiBackupInspection _inspectDecoded(Object? decoded) {
    if (decoded is! Map) {
      return const ShuatiBackupInspection.failure('备份根节点必须是 JSON 对象');
    }
    try {
      return _inspectMap(Map<String, Object?>.from(decoded));
    } on _InvalidBackup catch (error) {
      return ShuatiBackupInspection.failure(error.message);
    } on TypeError {
      return const ShuatiBackupInspection.failure('备份根节点必须是 JSON 对象');
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
    if (questions.length > maxEntriesPerCollection) {
      throw const _InvalidBackup('备份字段 questions 超过条目上限');
    }

    final issues = <ShuatiBackupIssue>[];
    final banks = _readList(map, 'banks');
    final bankIds = <String>{};
    for (final entry in banks) {
      if (entry is! Map) {
        _addIssue(
          issues,
          const ShuatiBackupIssue(
            ShuatiBackupIssueCode.malformedEntry,
            '题库条目不是对象，已忽略',
          ),
        );
        continue;
      }
      final id = entry['id'];
      if (id is! String || id.isEmpty) {
        _addIssue(
          issues,
          const ShuatiBackupIssue(
            ShuatiBackupIssueCode.missingBankId,
            '题库缺少 id',
          ),
        );
      } else if (!bankIds.add(id)) {
        _addIssue(
          issues,
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
    var totalQuestionEntries = 0;
    for (final items in questions.values) {
      if (items is List) {
        totalQuestionEntries += items.length;
        if (totalQuestionEntries > maxEntriesPerCollection) {
          throw const _InvalidBackup('备份字段 questions 超过条目上限');
        }
      }
    }

    for (final bucket in questions.entries) {
      final items = bucket.value;
      if (items is! List) {
        _addIssue(
          issues,
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
          _addIssue(
            issues,
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
      _addIssue(
        issues,
        const ShuatiBackupIssue(
          ShuatiBackupIssueCode.missingQuestionId,
          '题目缺少 id',
        ),
      );
    } else if (!questionIds.add(questionId)) {
      _addIssue(
        issues,
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.duplicateQuestionId,
          '题目 id 重复',
          detail: questionId,
        ),
      );
    }

    final bankId = item['bankId'];
    if (bankId is! String || bankId.isEmpty) {
      _addIssue(
        issues,
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.missingBankId,
          '题目缺少 bankId',
          detail: questionId,
        ),
      );
    } else if (!bankIds.contains(bankId)) {
      _addIssue(
        issues,
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.unknownBankId,
          '题目 bankId 不在题库列表中',
          detail: bankId,
        ),
      );
    }

    final type = item['type'];
    if (type is! String || !questionTypes.contains(type)) {
      _addIssue(
        issues,
        ShuatiBackupIssue(
          ShuatiBackupIssueCode.unknownQuestionType,
          '题目 type 未知',
          detail: '$type',
        ),
      );
    }

    final answer = item['answer'];
    if (answer is! List || answer.isEmpty) {
      _addIssue(
        issues,
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
    return key is String && isAiOrSecretSettingKey(key);
  }

  static List<Object?> _readList(Map<String, Object?> map, String field) {
    final value = map[field];
    if (value == null) return const [];
    if (value is List) {
      if (value.length > maxEntriesPerCollection) {
        throw _InvalidBackup('备份字段 $field 超过条目上限');
      }
      return value;
    }
    throw _InvalidBackup('备份字段 $field 必须是数组');
  }

  static void _addIssue(
    List<ShuatiBackupIssue> issues,
    ShuatiBackupIssue issue,
  ) {
    if (issues.length >= maxIssuesReported) {
      throw const _InvalidBackup('备份校验问题超过报告上限');
    }
    issues.add(issue);
  }
}

class _InvalidBackup implements Exception {
  const _InvalidBackup(this.message);

  final String message;
}
