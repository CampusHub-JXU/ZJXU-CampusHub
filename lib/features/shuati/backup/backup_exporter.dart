/// 导出原生数据为 PWA `ExportDataV3` 兼容的 JSON / ZIP（PWA `exportService.ts`）。
///
/// 导出的文件可以被旧版 PWA 的「恢复备份」直接读取，也可以被本模块的
/// [ShuatiBackupImporter] 再次导入（往返）。与 PWA 一致：
///
/// - `aiExplanations` / `settings` / `wrongQuestions` 为空时**省略字段**；
/// - 设置里的 AI / 凭据类 key 永远不导出；
/// - **不含** `practiceSessions`（V3 本就没有这个数组）。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../persistence/shuati_store.dart';
import 'backup_prepare.dart' show kBackupJsonEntry;

class ShuatiBackupExporter {
  ShuatiBackupExporter(
    this.store, {
    DateTime Function()? clock,
    this.useIsolate = true,
  }) : _clock = clock ?? DateTime.now;

  final ShuatiStore store;
  final DateTime Function() _clock;
  final bool useIsolate;

  /// 组装 `ExportDataV3` 的 Map（所有值都是 JSON 原生类型）。
  Future<Map<String, Object?>> buildExportData() async {
    final banks = await store.banks.getAllBanks();
    final allQuestions = await store.questions.getAll();
    final records = await store.records.getAll();
    final favorites = await store.favorites.getAll();
    final ai = await store.aiExplanations.getAll();
    final settings = await store.settings.getForExport();
    final wrong = await store.wrongQuestions.getAll();

    final byBank = <String, List<Map<String, Object?>>>{};
    for (final q in allQuestions) {
      byBank.putIfAbsent(q.bankId, () => []).add(q.toJson());
    }

    return {
      'version': 3,
      'exportedAt': _clock().millisecondsSinceEpoch,
      'banks': [for (final b in banks) b.toJson()],
      'questions': byBank,
      'records': [for (final r in records) r.toJson()],
      'favorites': [for (final f in favorites) f.toJson()],
      if (ai.isNotEmpty) 'aiExplanations': [for (final a in ai) a.toJson()],
      if (settings.isNotEmpty)
        'settings': [for (final s in settings) s.toJson()],
      if (wrong.isNotEmpty)
        'wrongQuestions': [for (final w in wrong) w.toJson()],
    };
  }

  /// 紧凑 JSON 文本（PWA `exportAllData`）。
  Future<String> exportJson() async {
    final data = await buildExportData();
    if (!useIsolate) return jsonEncode(data);
    return Isolate.run(() => jsonEncode(data));
  }

  /// ZIP 字节，仅含 `backup.json`（PWA `exportAllAsZip`，deflate level 9）。
  Future<Uint8List> exportZip() async {
    final json = await exportJson();
    if (!useIsolate) return _zip(json);
    return Isolate.run(() => _zip(json));
  }

  /// 单个题库的题目数组，缩进 2 空格（PWA `exportBankQuestions`）。
  Future<String> exportBankQuestionsJson(String bankId) async {
    final questions = await store.questions.getByBank(bankId);
    return const JsonEncoder.withIndent('  ')
        .convert([for (final q in questions) q.toJson()]);
  }
}

Uint8List _zip(String json) {
  final archive = Archive()
    ..addFile(ArchiveFile.bytes(kBackupJsonEntry, utf8.encode(json)));
  return ZipEncoder().encodeBytes(archive, level: 9);
}
