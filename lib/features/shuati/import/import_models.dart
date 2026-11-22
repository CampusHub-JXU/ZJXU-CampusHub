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
