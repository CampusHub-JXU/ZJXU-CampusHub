/// 题库文件导入的类型：格式、失败码、逐条拒绝原因、导入报告。
///
/// 报告与错误**不含题目内容**（只有计数、行号 / 序号和固定原因码），
/// 可以安全地展示、写日志。
library;

import '../domain/shuati_models.dart';

/// 支持的题库文件格式（按扩展名）。
enum ShuatiImportFormat {
  json,
  csv,
  xlsx,
  docx,
  txt,
  md;

  /// 按扩展名（不含点、已小写）识别；`xls` 返回 `null`（见 [ShuatiImportFailure.legacyXls]）。
  static ShuatiImportFormat? fromExtension(String ext) {
    for (final f in ShuatiImportFormat.values) {
      if (f.name == ext) return f;
    }
    return null;
  }

  /// docx / txt / md 可「同源覆盖更新」（按 `sourceFileName` 匹配既有题库）。
  bool get isReimportable =>
      this == ShuatiImportFormat.docx ||
      this == ShuatiImportFormat.txt ||
      this == ShuatiImportFormat.md;
}

/// 整个文件无法导入的原因。
enum ShuatiImportFailureCode {
  /// 扩展名不受支持。
  unsupportedFormat,

  /// `.xls`（BIFF 二进制）：PWA 靠 SheetJS 能读，原生没有对应的纯 Dart 解析器。
  legacyXls,

  /// 文件超过大小上限。
  fileTooLarge,

  /// 文件为空。
  emptyFile,

  /// JSON 语法错误。
  invalidJson,

  /// JSON 根不是数组 / 含 `questions` 数组的对象。
  invalidJsonShape,

  /// xlsx / docx 不是合法 zip，或缺必需部件，或解压超限。
  corruptArchive,

  /// 解析后一道题也没有。
  noQuestionsParsed,
}

/// 导入失败（整个文件被拒绝，库未改动）。
class ShuatiImportFailure implements Exception {
  const ShuatiImportFailure(this.code, this.message);

  final ShuatiImportFailureCode code;

  /// 面向用户的中文说明（PWA 同名场景沿用其原文案）。
  final String message;

  @override
  String toString() => 'ShuatiImportFailure(${code.name}): $message';
}

/// 单条题目被拒绝（跳过）的原因。
enum ImportRejectionReason {
  /// JSON 数组元素不是对象。
  notAnObject,

  /// 缺少题干 / 题干为空。
  missingQuestionText,

  /// `options` 形态不合法（元素不是字符串等）。
  invalidOptions,

  /// 规范化 / 解析抛出未预期异常。
  unexpectedError,
}

/// 一条被拒绝的条目（`index` 为 0 起的源序号，不含内容）。
class ImportRejection {
  const ImportRejection(this.index, this.reason);

  final int index;
  final ImportRejectionReason reason;
}

/// 非致命提示（报告里展示，不影响导入成败）。
enum ImportWarning {
  /// 文本不是合法 UTF-8，已按 GBK 解码。
  decodedAsGbk,

  /// 文本含无法解码的字节，已用替换字符代替。
  lossyDecoding,

  /// 有题目没有答案（可导入，但练习页无法作答）。
  questionsWithoutAnswer,

  /// 有题目 id 与库内或批内已有 id 冲突，已重新生成。
  idsRegenerated,

  /// 全部题目都是重复题，没有创建新题库。
  allDuplicates,
}

/// 导入报告。
class ShuatiImportReport {
  const ShuatiImportReport({
    required this.format,
    required this.parsed,
    required this.added,
    required this.duplicates,
    required this.conflicts,
    required this.invalid,
    required this.rejections,
    required this.rejectionCounts,
    required this.withoutAnswer,
    required this.idsRegenerated,
    required this.warnings,
    this.bank,
    this.updatedExisting = false,
    this.updatedQuestions = 0,
    this.removedQuestions = 0,
  });

  final ShuatiImportFormat format;

  /// 目标题库；全部为重复题且未建库时为 `null`。
  final QuestionBank? bank;

  /// 是否为「同源覆盖更新」。
  final bool updatedExisting;

  /// 解析阶段得到的条目数（含将被拒绝 / 去重的）。
  final int parsed;

  /// 实际写入的新题数（PWA `count`）。同源更新时为「新文件里保留的题数」。
  final int added;

  /// 与已有题 contentHash + answerHash 均相同而跳过（PWA `skipped`）。
  final int duplicates;

  /// contentHash 相同但答案不同（仍然导入，PWA `conflicts`）。
  final int conflicts;

  /// 被拒绝的条目数（总数；[rejections] 仅保留前若干条样例）。
  final int invalid;
  final List<ImportRejection> rejections;
  final Map<ImportRejectionReason, int> rejectionCounts;

  /// 没有答案的题数。
  final int withoutAnswer;
  final int idsRegenerated;
  final List<ImportWarning> warnings;

  /// 同源更新：沿用旧 id 覆盖的题数 / 被删除的旧题数。
  final int updatedQuestions;
  final int removedQuestions;
}

// ============ 两段式导入（解析预览 → 确认落库） ============

/// 预览页对已解析题目的单条修正（例如勾选 AI 建议的答案 / 解析）。
///
/// [index] 对应 [ShuatiImportPreview.questions] 的下标；`answer` / `explanation`
/// 为 `null` 的字段不改。改动答案会重算 `answerHash` 并计入去重统计。
class ParsedQuestionOverride {
  const ParsedQuestionOverride({
    required this.index,
    this.answer,
    this.explanation,
  });

  final int index;
  final List<String>? answer;
  final String? explanation;
}

/// 解析 + 去重的预演结果（Issue #117 预览接口）。
///
/// 只读快照，可以来回展示多次；落库走 [ShuatiImportService.commitPreview]，
/// 提交时才真正查库去重 / 重生成 id / 单事务写入。
class ShuatiImportPreview {
  const ShuatiImportPreview({
    required this.format,
    required this.fileName,
    required this.extension,
    required this.bankName,
    required this.bankId,
    required this.existingBankId,
    required this.existingBankName,
    required this.questions,
    required this.parsedCount,
    required this.invalid,
    required this.rejections,
    required this.rejectionCounts,
    required this.missingAnswerIndexes,
    required this.duplicates,
    required this.conflicts,
    required this.newQuestionCount,
    required this.warnings,
  });

  /// 识别出的文件格式与原始文件名 / 扩展名（不含点、已小写）。
  final ShuatiImportFormat format;
  final String fileName;
  final String extension;

  /// 默认题库名（文件名去扩展 / JSON `name`）；commit 时可用 `bankName` 覆盖。
  final String bankName;

  /// 解析时分配给题目的 `bankId`：新建题库时就是新库 id，
  /// 命中同源既有题库时为该库 id（commit 必须沿用，不能重新生成）。
  final String bankId;

  /// 同源覆盖更新命中的既有题库；非同源格式 / 无命中时为 `null`。
  final String? existingBankId;
  final String? existingBankName;

  /// 更新既有题库（[existingBankId] 非空）时为 `true`。
  bool get updatesExisting => existingBankId != null;

  /// 规范化并带 hash 的原始解析题目（未应用任何用户修正）。
  final List<Question> questions;

  /// 解析阶段得到的条目总数（含被拒绝的）。
  final int parsedCount;

  /// 解析阶段被拒绝的条目数 / 样例 / 分原因计数。
  final int invalid;
  final List<ImportRejection> rejections;
  final Map<ImportRejectionReason, int> rejectionCounts;

  /// `questions` 里缺答案题的下标（供预览页做 AI 补全入口）。
  final List<int> missingAnswerIndexes;

  /// 去重预演：与既有题库（或批内首条）重复的题数 / 同内容不同答案的冲突数。
  final int duplicates;
  final int conflicts;

  /// 去重后预计写入的题数。
  final int newQuestionCount;

  /// 解析阶段的非致命提示（编码、缺答案等；id 重生成只在 commit 后才知道）。
  final List<ImportWarning> warnings;
}
