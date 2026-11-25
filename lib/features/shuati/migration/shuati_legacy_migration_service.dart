/// 旧版 WebView（PWA）数据自动迁移服务。
///
/// 流程：不可见的 headless WebView 在旧 PWA 同源（`shuati.local.app`）里读取
/// IndexedDB `ShuaTiDB` 全表与 localStorage `practice-progress-*` →
/// [buildLegacyMigrationArtifacts] 转成备份 JSON + 会话计划 →
/// `ShuatiBackupImporter`（默认幂等 merge）落库 → 练习会话以「本地优先、
/// 冲突不覆盖」写入 → `SharedPreferences` 记录完成标记。
///
/// 幂等性：备份导入本身幂等（同一旧库重复跑行数不变）；会话写入用
/// `INSERT OR IGNORE`，手动重复触发也不会覆盖本地更新的断点。
///
/// 安全边界：
/// - 只读旧数据，绝不删除 / 清空 WebView 存储（`indexedDB.databases()` 探测 +
///   `onupgradeneeded` 中 abort，不会为没有旧数据的设备创建空库）；
/// - AI / 凭据类设置在备份清洗阶段即被丢弃（与文件备份同一条管线）；
/// - 失败不写完成标记，下次进入还会重试；连续失败达到上限后停止自动重试
///   （手动入口不受影响），避免每次开页都白跑一次 headless WebView。
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/logging/app_logger.dart';
import '../backup/backup_importer.dart';
import '../backup/backup_models.dart';
import '../backup/backup_prepare.dart';
import '../persistence/row_mappers.dart';
import '../persistence/shuati_database.dart';
import '../persistence/shuati_store.dart';
import 'legacy_payload.dart';
import 'shuati_legacy_extractor.dart';

/// 迁移结果状态。
enum ShuatiLegacyMigrationStatus {
  /// 检测到旧数据并完成导入（`report` 非空；题目数可能为 0 但仍属成功）。
  migrated,

  /// 旧 WebView 里没有任何数据（空库 / 从未使用）；仅记录完成标记。
  noLegacyData,

  /// 本次未执行：自动路径下完成标记已存在，或原生库非空。
  skipped,

  /// 提取 / 解析 / 导入失败（库未改动；`error` 含非敏感描述）。
  failed,
}

class ShuatiLegacyMigrationOutcome {
  const ShuatiLegacyMigrationOutcome({
    required this.status,
    this.report,
    this.sessionsWritten = 0,
    this.derivedWrongCount = 0,
    this.error,
  });

  final ShuatiLegacyMigrationStatus status;

  /// 备份导入报告（[ShuatiLegacyMigrationStatus.migrated] 时非空）。
  final ShuatiBackupImportReport? report;

  /// 本次新写入的练习会话行数（幂等：重复执行时已有行不计）。
  final int sessionsWritten;

  /// 因旧库没有 `wrongQuestions` 表而从记录推导的错题条数。
  final int derivedWrongCount;

  /// 失败原因（不含题目内容）。
  final String? error;

  bool get migratedWithData => status == ShuatiLegacyMigrationStatus.migrated;
}

/// 偏好存取的可注入点（默认 `SharedPreferences`；测试注入内存实现）。
abstract class ShuatiMigrationPrefs {
  Future<bool> getBool(String key);
  Future<int> getInt(String key);
  Future<void> setBool(String key, bool value);
  Future<void> setInt(String key, int value);
}

class SharedPreferencesMigrationPrefs implements ShuatiMigrationPrefs {
  const SharedPreferencesMigrationPrefs();

  @override
  Future<bool> getBool(String key) async =>
      (await SharedPreferences.getInstance()).getBool(key) ?? false;

  @override
  Future<int> getInt(String key) async =>
      (await SharedPreferences.getInstance()).getInt(key) ?? 0;

  @override
  Future<void> setBool(String key, bool value) async =>
      (await SharedPreferences.getInstance()).setBool(key, value);

  @override
  Future<void> setInt(String key, int value) async =>
      (await SharedPreferences.getInstance()).setInt(key, value);
}

class ShuatiLegacyMigrationService {
  ShuatiLegacyMigrationService({
    required this.store,
    required this.extractor,
    ShuatiMigrationPrefs? prefs,
    ShuatiBackupImporter Function(ShuatiStore store)? importerFactory,
  }) : prefs = prefs ?? const SharedPreferencesMigrationPrefs(),
       _importerFactory =
           importerFactory ?? ((store) => ShuatiBackupImporter(store));

  static const String completedKey = 'shuati_legacy_migration_completed';
  static const String failureCountKey = 'shuati_legacy_migration_failures';

  /// 自动迁移连续失败达到此次数后停止自动重试（手动「从旧版迁移」仍可用）。
  static const int maxAutoFailures = 3;

  final ShuatiStore store;
  final ShuatiLegacyExtractor extractor;
  final ShuatiMigrationPrefs prefs;
  final ShuatiBackupImporter Function(ShuatiStore store) _importerFactory;

  /// 自动路径是否应当尝试：未完成标记、连续失败未达上限、原生库为空。
  ///
  /// 「原生库为空」以题库 / 题目 / 作答记录三表全空判定——用户一旦在原生里
  /// 导入过题库或做过题，就不再自动跑（手动入口仍可强制合并）。
  Future<bool> shouldAutoMigrate() async {
    if (await prefs.getBool(completedKey)) return false;
    if (await prefs.getInt(failureCountKey) >= maxAutoFailures) return false;
    return _isNativeDatabaseEmpty();
  }

  Future<bool> _isNativeDatabaseEmpty() async {
    final rows = await store.executor.rawQuery('''
SELECT
  (SELECT COUNT(*) FROM ${ShuatiSchema.tableBanks}) +
  (SELECT COUNT(*) FROM ${ShuatiSchema.tableQuestions}) +
  (SELECT COUNT(*) FROM ${ShuatiSchema.tableRecords}) AS c
''');
    return (rows.first['c']! as int) == 0;
  }

  /// 自动迁移入口：满足 [shouldAutoMigrate] 才执行，否则返回 `skipped`。
  Future<ShuatiLegacyMigrationOutcome> migrateIfNeeded() async {
    if (!await shouldAutoMigrate()) {
      return const ShuatiLegacyMigrationOutcome(
        status: ShuatiLegacyMigrationStatus.skipped,
      );
    }
    return _run();
  }

  /// 手动迁移入口（设置页「从旧版迁移」）：总是执行；合并幂等，不删本地数据。
  Future<ShuatiLegacyMigrationOutcome> migrateNow() => _run();

  Future<ShuatiLegacyMigrationOutcome> _run() async {
    final ShuatiLegacyExtraction extraction;
    try {
      extraction = await extractor.extract();
    } catch (e) {
      await _recordFailure();
      final message = '旧版数据读取失败';
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.storage,
        '刷题助手旧版迁移：提取失败',
        error: e,
      );
      return ShuatiLegacyMigrationOutcome(
        status: ShuatiLegacyMigrationStatus.failed,
        error: message,
      );
    }

    if (extraction.isEmpty) {
      await _markCompleted();
      return const ShuatiLegacyMigrationOutcome(
        status: ShuatiLegacyMigrationStatus.noLegacyData,
      );
    }

    try {
      final artifacts = buildLegacyMigrationArtifacts(extraction);
      final prepared = await prepareBackup(artifacts.backupJson);
      final report = await _importerFactory(store).importPrepared(prepared);
      final sessionsWritten = await _writeSessions(artifacts);
      await _markCompleted();
      AppLogger.instance.log(
        LogLevel.info,
        LogCategory.storage,
        '刷题助手旧版迁移完成：banks+${report.banks.added} '
        'questions+${report.questions.added} records+${report.records.added} '
        'sessions+$sessionsWritten derivedWrong=${artifacts.derivedWrongCount}',
      );
      return ShuatiLegacyMigrationOutcome(
        status: ShuatiLegacyMigrationStatus.migrated,
        report: report,
        sessionsWritten: sessionsWritten,
        derivedWrongCount: artifacts.derivedWrongCount,
      );
    } catch (e) {
      await _recordFailure();
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.storage,
        '刷题助手旧版迁移：导入失败（库未改动）',
        error: e,
      );
      return const ShuatiLegacyMigrationOutcome(
        status: ShuatiLegacyMigrationStatus.failed,
        error: '旧版数据导入失败',
      );
    }
  }

  /// 会话写入：与备份导入同事务语义不必要（会话引用题库，导入已提交；
  /// 失败仅影响断点续练），单独一个事务 `INSERT OR IGNORE`，本地已有行优先。
  Future<int> _writeSessions(ShuatiLegacyMigrationArtifacts artifacts) async {
    if (artifacts.sessions.isEmpty) return 0;
    return store.runInTransaction((tx) async {
      var written = 0;
      for (final session in artifacts.sessions) {
        // 外键约束：题库必须存在（解析阶段已按备份题库过滤，再防御一次）。
        final bank = await tx.executor.query(
          ShuatiSchema.tableBanks,
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [session.bankId],
          limit: 1,
        );
        if (bank.isEmpty) continue;
        final changed = await tx.executor.insert(
          ShuatiSchema.tablePracticeSessions,
          sessionToRow(session),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (changed != 0) written++;
      }
      return written;
    });
  }

  Future<void> _markCompleted() async {
    await prefs.setBool(completedKey, true);
    await prefs.setInt(failureCountKey, 0);
  }

  Future<void> _recordFailure() async {
    final current = await prefs.getInt(failureCountKey);
    await prefs.setInt(failureCountKey, current + 1);
  }
}
