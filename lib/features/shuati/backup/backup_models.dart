/// 备份导入的类型：失败码、逐集合计数、报告。报告不含题目内容。
library;

import '../shuati_backup_schema.dart';

/// 导入模式。
enum BackupImportMode {
  /// 合并（默认、幂等）：已存在的 id / 记录原样保留，缺的补上；绝不删除本地数据。
  merge,

  /// 替换（PWA `importFullBackup` 的原语义）：先清空全部数据再写入备份。
  replaceAll,
}

/// 备份整体无法导入的原因（库未改动）。
enum ShuatiBackupFailureCode {
  /// 文件过大。
  tooLarge,

  /// ZIP 损坏 / 超限 / 不受支持。
  corruptArchive,

  /// ZIP 里没有 `backup.json`。
  missingBackupJson,

  /// JSON 语法错误 / 根不是对象。
  invalidJson,

  /// 版本不是 1 / 2 / 3，或集合类型 / 数量不符合 [ShuatiBackupSchema] 的限制。
  unsupported,

  /// 写入后完整性校验未通过（事务已回滚）。
  integrityCheckFailed,
}

class ShuatiBackupFailure implements Exception {
  const ShuatiBackupFailure(this.code, this.message);

  final ShuatiBackupFailureCode code;
  final String message;

  @override
  String toString() => 'ShuatiBackupFailure(${code.name}): $message';
}

/// 一个集合的导入计数。
class BackupCollectionCounts {
  const BackupCollectionCounts({
    this.added = 0,
    this.duplicate = 0,
    this.orphan = 0,
    this.invalid = 0,
    this.merged = 0,
  });

  /// 新写入的行数。
  final int added;

  /// 本地已有（幂等命中）而跳过的行数。
  final int duplicate;

  /// 引用了不存在的题库 / 题目而丢弃的行数。
  final int orphan;

  /// 结构不合法（缺字段 / 类型错）而丢弃的行数。
  final int invalid;

  /// 与本地已有行合并更新的行数（目前仅永久错题）。
  final int merged;

  int get total => added + duplicate + orphan + invalid + merged;
}

/// 备份导入报告。
class ShuatiBackupImportReport {
  const ShuatiBackupImportReport({
    required this.version,
    required this.mode,
    required this.banks,
    required this.questions,
    required this.records,
    required this.favorites,
    required this.wrongQuestions,
    required this.aiExplanations,
    required this.settings,
    required this.droppedAiSettings,
    required this.idsRemapped,
    required this.typesInferred,
    required this.hashesBackfilled,
    required this.issues,
  });

  /// 备份声明的版本（1 / 2 / 3）。
  final int version;
  final BackupImportMode mode;

  final BackupCollectionCounts banks;
  final BackupCollectionCounts questions;
  final BackupCollectionCounts records;
  final BackupCollectionCounts favorites;
  final BackupCollectionCounts wrongQuestions;
  final BackupCollectionCounts aiExplanations;
  final BackupCollectionCounts settings;

  /// 因是 AI / 凭据类设置而丢弃的条数（**从不保存**，不论模式）。
  final int droppedAiSettings;

  /// 因题目 id 与库内另一题库的题冲突而重新生成 id 的题数。
  final int idsRemapped;

  /// 备份里 `type` 非法、按 PWA 题型推断规则补全的题数。
  final int typesInferred;

  /// 缺 contentHash / answerHash、导入时补算的题数。
  final int hashesBackfilled;

  /// [ShuatiBackupSchema.inspectJson] 发现的结构问题（非致命）。
  final List<ShuatiBackupIssue> issues;
}
