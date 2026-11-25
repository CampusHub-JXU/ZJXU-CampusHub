/// 旧版 WebView（PWA）数据提取结果的纯解析与转换，无 Flutter / WebView 依赖，
/// 可以完全离线单测。
///
/// 输入 = `ShuatiLegacyHeadlessExtractor` 在旧 PWA 同源页面里跑 JS 得到的 JSON：
/// IndexedDB `ShuaTiDB` 各 ObjectStore 的全量行（`getAll()`）+
/// localStorage 里 `practice-progress-*` 的原始字符串。
///
/// 输出 = `ShuatiBackupImporter` 可消费的备份 JSON（V3 形态）+ 练习会话写入计划。
library;

import 'dart:convert';

import '../domain/practice_session.dart';
import '../domain/practice_selection.dart';
import '../domain/shuati_models.dart';

/// IndexedDB 数据库名（以打包的 PWA 源码 `src/db/index.ts` / 产物 bundle 为准）。
const String kShuatiLegacyDbName = 'ShuaTiDB';

/// localStorage 顺序练习进度前缀（PWA `practice-progress-${bankId}-sequential`）。
const String kLegacyProgressKeyPrefix = 'practice-progress-';

/// 进度 key 的后缀 `-sequential`（PracticeMode.sequential.name）。
const String _legacyProgressModeSuffix = '-sequential';

/// 一次提取的原始内容。字段均为可 JSON 序列化的松散结构，
/// 由 [buildLegacyMigrationArtifacts] 进一步清洗。
class ShuatiLegacyExtraction {
  const ShuatiLegacyExtraction({
    this.databaseVersion,
    this.storeNames = const [],
    this.stores = const {},
    this.progressByKey = const {},
  });

  /// IndexedDB 的实际版本号（Dexie 声明版本 × 10；仅诊断用）。
  final int? databaseVersion;

  /// 实际存在的 ObjectStore 名。
  final List<String> storeNames;

  /// store 名 → `getAll()` 的行数组。
  final Map<String, List<Object?>> stores;

  /// localStorage `practice-progress-${bankId}-sequential` → 原始 JSON 字符串。
  final Map<String, String> progressByKey;

  bool get isEmpty =>
      stores.values.every((rows) => rows.isEmpty) && progressByKey.isEmpty;

  /// 宽松解析 JS 侧返回的对象；结构不符返回 `null`（视为提取失败）。
  static ShuatiLegacyExtraction? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final storesRaw = json['stores'];
    final progressRaw = json['progress'];
    if (storesRaw is! Map) return null;
    final stores = <String, List<Object?>>{};
    for (final entry in storesRaw.entries) {
      final key = entry.key;
      final rows = entry.value;
      if (key is String && rows is List) {
        stores[key] = rows.cast<Object?>();
      }
    }
    final progress = <String, String>{};
    if (progressRaw is Map) {
      for (final entry in progressRaw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String) progress[key] = value;
      }
    }
    final storeNames = json['storeNames'];
    return ShuatiLegacyExtraction(
      databaseVersion: jsonInt(json['databaseVersion']),
      storeNames: storeNames is List
          ? [
              for (final n in storeNames)
                if (n is String) n,
            ]
          : stores.keys.toList(),
      stores: stores,
      progressByKey: progress,
    );
  }
}

/// 转换产物：[backupJson] 喂给 `prepareBackup` + `importPrepared`；
/// [sessions] 在导入成功后**幂等地**写入练习会话表（本地已有同名行时不覆盖）。
class ShuatiLegacyMigrationArtifacts {
  const ShuatiLegacyMigrationArtifacts({
    required this.backupJson,
    required this.sessions,
    required this.derivedWrongCount,
    required this.droppedRows,
  });

  /// V3 形态的备份 JSON 文本（含由记录推导的 `wrongQuestions`）。
  final String backupJson;

  /// 待写入的练习会话（含 IndexedDB `practiceSessions` 与 localStorage 兜底合成）。
  final List<PracticeSessionRecord> sessions;

  /// 因旧库没有 `wrongQuestions` 表而从作答记录推导出的错题条数。
  final int derivedWrongCount;

  /// 各集合因结构不合法 / 无法归属被丢弃的行数（诊断与日志用，键同备份集合）。
  final Map<String, int> droppedRows;

  /// 备份里没有任何题库行且没有可写入的会话（提取到的是空壳）。
  bool get isEmpty {
    final decoded = jsonDecode(backupJson);
    if (decoded is! Map) return sessions.isEmpty;
    final banks = decoded['banks'];
    final hasBankRows = banks is List && banks.isNotEmpty;
    return !hasBankRows && sessions.isEmpty;
  }
}

List<Object?> _list(Object? value) =>
    value is List ? value.cast<Object?>() : const [];

Map<String, Object?>? _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

/// 把提取结果转换为备份 JSON + 会话计划。
///
/// - `questions` 按 `bankId` 归桶（缺 `bankId` 的丢弃并计数）；
/// - 若旧库**没有** `wrongQuestions` 表（打包 PWA 为 schema v5，确实没有），
///   按「每题最新有效作答为 wrong」推导永久错题条目：`firstWrongAt` / `wrongCount`
///   取自全部 wrong 记录，`lastWrongAt` / `lastRecordId` 取最新一条 wrong 记录；
///   若有该表（未来版本）则**原样透传**，不再推导；
/// - `practiceSessions` 表逐行校验（题库存在、模式合法、考试模式除外——
///   PWA 本就不保存考试会话，防御性跳过）；localStorage `practice-progress-*` 仅对
///   没有 IndexedDB 顺序会话的题库补合成（用题库的**题库顺序**作为题单）。
ShuatiLegacyMigrationArtifacts buildLegacyMigrationArtifacts(
  ShuatiLegacyExtraction extraction,
) {
  final dropped = <String, int>{};
  void bump(String key) => dropped[key] = (dropped[key] ?? 0) + 1;

  // ---- banks ----
  final banks = <Map<String, Object?>>[];
  final bankIds = <String>{};
  for (final raw in _list(extraction.stores['banks'])) {
    final map = _asMap(raw);
    final id = map?['id'];
    if (map == null || id is! String || id.isEmpty) {
      bump('banks');
      continue;
    }
    if (!bankIds.add(id)) continue; // 重复 id 保留第一条
    banks.add(map);
  }

  // ---- questions（按 bankId 归桶）----
  final questionsByBank = <String, List<Map<String, Object?>>>{
    for (final id in bankIds) id: [],
  };
  for (final raw in _list(extraction.stores['questions'])) {
    final map = _asMap(raw);
    final bankId = map?['bankId'];
    if (map == null || bankId is! String || bankId.isEmpty) {
      bump('questions');
      continue;
    }
    // 桶不存在（孤儿题）也照样保留——备份 schema 会记 orphan issue，
    // 导入阶段统一丢弃计数，与文件备份路径行为一致。
    questionsByBank.putIfAbsent(bankId, () => []).add(map);
  }

  // ---- records / favorites / aiExplanations / settings（原样透传，清洗交给管线）----
  List<Object?> passthrough(String store, String collectionKey) {
    final rows = <Object?>[];
    for (final raw in _list(extraction.stores[store])) {
      if (_asMap(raw) == null) {
        bump(collectionKey);
      } else {
        rows.add(raw);
      }
    }
    return rows;
  }

  final records = passthrough('records', 'records');
  final favorites = passthrough('favorites', 'favorites');
  final aiExplanations = passthrough('aiExplanations', 'aiExplanations');
  final settings = passthrough('settings', 'settings');

  // ---- wrongQuestions：有表透传，无表推导 ----
  final explicitWrong = passthrough('wrongQuestions', 'wrongQuestions');
  final wrongRows = <Map<String, Object?>>[];
  var derivedWrong = 0;
  if (explicitWrong.isNotEmpty) {
    for (final raw in explicitWrong) {
      wrongRows.add((raw as Map).cast<String, Object?>());
    }
  } else {
    final parsed = <PracticeRecord>[];
    for (final raw in records) {
      final r = PracticeRecord.tryFromJson(raw);
      if (r != null) parsed.add(r);
    }
    derivedWrong = _deriveWrongRows(parsed, wrongRows);
  }

  final backup = <String, Object?>{
    'version': 3,
    'exportedAt': 0,
    'banks': banks,
    'questions': questionsByBank,
    'records': records,
    'favorites': favorites,
    if (aiExplanations.isNotEmpty) 'aiExplanations': aiExplanations,
    if (settings.isNotEmpty) 'settings': settings,
    if (wrongRows.isNotEmpty) 'wrongQuestions': wrongRows,
  };

  final sessions = _buildSessions(
    extraction,
    bankIds: bankIds,
    questionsByBank: questionsByBank,
    bump: bump,
  );

  return ShuatiLegacyMigrationArtifacts(
    backupJson: jsonEncode(backup),
    sessions: sessions,
    derivedWrongCount: derivedWrong,
    droppedRows: dropped,
  );
}

/// 从作答记录推导永久错题：最新有效作答为 wrong 的题。
/// `firstWrongAt` / `wrongCount` 统计全部 wrong 记录，`lastWrongAt` / `lastRecordId`
/// 取最新 wrong 记录。返回推导条数。
int _deriveWrongRows(
  List<PracticeRecord> records,
  List<Map<String, Object?>> out,
) {
  final latest = latestRecordsByQuestion(records);
  var count = 0;
  for (final entry in latest.entries) {
    if (entry.value.status != AnswerStatus.wrong) continue;
    final questionId = entry.key;
    final bankId = entry.value.bankId;
    final wrongs = [
      for (final r in records)
        if (r.questionId == questionId && r.status == AnswerStatus.wrong) r,
    ];
    if (wrongs.isEmpty) continue;
    var first = wrongs.first.timestamp;
    var lastWrong = wrongs.first;
    for (final w in wrongs) {
      if (w.timestamp < first) first = w.timestamp;
      final newer =
          w.timestamp > lastWrong.timestamp ||
          (w.timestamp == lastWrong.timestamp &&
              (w.id ?? 0) > (lastWrong.id ?? 0));
      if (newer) lastWrong = w;
    }
    out.add({
      'bankId': bankId,
      'questionId': questionId,
      'firstWrongAt': first,
      'lastWrongAt': lastWrong.timestamp,
      'wrongCount': wrongs.length,
      if (lastWrong.id != null) 'lastRecordId': lastWrong.id,
    });
    count++;
  }
  return count;
}

List<PracticeSessionRecord> _buildSessions(
  ShuatiLegacyExtraction extraction, {
  required Set<String> bankIds,
  required Map<String, List<Map<String, Object?>>> questionsByBank,
  required void Function(String key) bump,
}) {
  final sessions = <PracticeSessionRecord>[];
  final coveredSequentialBanks = <String>{};

  for (final raw in _list(extraction.stores['practiceSessions'])) {
    final map = _asMap(raw);
    if (map == null) {
      bump('practiceSessions');
      continue;
    }
    final session = _tryParseLegacySession(map, bankIds: bankIds);
    if (session == null) {
      bump('practiceSessions');
      continue;
    }
    if (session.mode == PracticeMode.sequential &&
        session.id != lastSessionId) {
      coveredSequentialBanks.add(session.bankId);
    }
    sessions.add(session);
  }

  // localStorage 兜底：只对没有 IndexedDB 顺序会话的题库合成。
  final sortedKeys = extraction.progressByKey.keys.toList()..sort();
  for (final key in sortedKeys) {
    final bankId = _progressKeyBankId(key);
    if (bankId == null ||
        !bankIds.contains(bankId) ||
        coveredSequentialBanks.contains(bankId)) {
      continue;
    }
    final saved = parseSavedProgress(
      extraction.progressByKey[key],
      PracticeMode.sequential,
    );
    if (saved == null) continue;
    final questionIds = [
      for (final q in questionsByBank[bankId] ?? const [])
        if (q['id'] case final String id) id,
    ];
    if (questionIds.isEmpty) continue;
    sessions.add(
      PracticeSessionRecord(
        id: scopedSessionId(bankId, PracticeMode.sequential, null),
        bankId: bankId,
        mode: PracticeMode.sequential,
        currentIndex: saved.currentIndex.clamp(0, questionIds.length - 1),
        questionIds: questionIds,
        updatedAt: 0,
      ),
    );
  }
  return sessions;
}

/// `practice-progress-${bankId}-sequential` → bankId（bankId 本身可含连字符，
/// 从尾部剥掉 `-sequential`）。
String? _progressKeyBankId(String key) {
  if (!key.startsWith(kLegacyProgressKeyPrefix)) return null;
  if (!key.endsWith(_legacyProgressModeSuffix)) return null;
  final start = kLegacyProgressKeyPrefix.length;
  final end = key.length - _legacyProgressModeSuffix.length;
  if (end <= start) return null;
  return key.substring(start, end);
}

PracticeSessionRecord? _tryParseLegacySession(
  Map<String, Object?> map, {
  required Set<String> bankIds,
}) {
  final id = map['id'];
  final bankId = map['bankId'];
  final mode = PracticeMode.tryParse(map['mode']);
  final questionIdsRaw = map['questionIds'];
  if (id is! String ||
      id.isEmpty ||
      bankId is! String ||
      !bankIds.contains(bankId) ||
      mode == null ||
      mode == PracticeMode.exam ||
      questionIdsRaw is! List) {
    return null;
  }
  final questionIds = [
    for (final q in questionIdsRaw)
      if (q is String && q.isNotEmpty) q,
  ];
  if (questionIds.isEmpty) return null;
  final typeFilter = QuestionType.tryParse(map['typeFilter']);
  return PracticeSessionRecord(
    id: id,
    bankId: bankId,
    mode: mode,
    typeFilter: typeFilter,
    currentIndex: (jsonInt(map['currentIndex']) ?? 0).clamp(
      0,
      questionIds.length - 1,
    ),
    questionIds: questionIds,
    updatedAt: jsonInt(map['updatedAt']) ?? 0,
  );
}
