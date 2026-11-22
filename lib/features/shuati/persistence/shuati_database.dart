/// 刷题助手本地 SQLite 数据库（`sqflite`）：schema、版本化迁移、打开 / 关闭。
///
/// 表与 PWA IndexedDB `ShuaTiDB` v6 一一对应（见 docs/shuati-native-parity.md §9），
/// 外加两处原生化改动：
///
/// - `questions.sort_order`：保存导入顺序。PWA 的顺序练习其实是 IndexedDB 在
///   `bankId` 索引上的主键（题目 id 字符串）序，对 UUID 题目等于「稳定的乱序」；
///   原生按导入 / 备份数组顺序固定下来；
/// - 外键 + 级联删除：删题库 / 删题自动清理 records / favorites / wrong_questions /
///   ai_explanations，不再靠应用层逐表删除。
library;

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/logging/app_logger.dart';

/// 数据库级失败（打开 / 迁移 / 降级）。消息不含题目内容。
class ShuatiDatabaseException implements Exception {
  const ShuatiDatabaseException(this.message);

  final String message;

  @override
  String toString() => 'ShuatiDatabaseException: $message';
}

/// 一次版本迁移：把库从 `version - 1` 升到 `version`。在 sqflite 的升级事务内执行。
typedef ShuatiMigration = Future<void> Function(Database db);

/// schema 定义与迁移表。
abstract final class ShuatiSchema {
  /// 当前 schema 版本（`PRAGMA user_version`）。
  static const int version = 1;

  /// 数据库文件名（位于应用文档目录）。
  static const String fileName = 'shuati.db';

  static const String tableBanks = 'banks';
  static const String tableQuestions = 'questions';
  static const String tableRecords = 'records';
  static const String tableFavorites = 'favorites';
  static const String tableWrongQuestions = 'wrong_questions';
  static const String tablePracticeSessions = 'practice_sessions';
  static const String tableSettings = 'settings';
  static const String tableAiExplanations = 'ai_explanations';

  /// 全部表（清库 / 完整性检查用，按外键依赖由子到父排序）。
  static const List<String> tablesChildFirst = [
    tableAiExplanations,
    tableWrongQuestions,
    tableFavorites,
    tableRecords,
    tablePracticeSessions,
    tableSettings,
    tableQuestions,
    tableBanks,
  ];

  /// 迁移表：key 为目标版本。v1 由 [create] 直接建出，故这里暂为空；
  /// 以后加列 / 加表时在此登记 `2: (db) async { ... }`，并把 [version] 加一。
  static final Map<int, ShuatiMigration> migrations = <int, ShuatiMigration>{};

  /// 全新安装：一次建出当前版本的全部表与索引。
  static Future<void> create(Database db) async {
    await db.execute('''
CREATE TABLE $tableBanks (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  question_count INTEGER NOT NULL DEFAULT 0,
  source_file_name TEXT,
  source_file_ext TEXT
)''');
    await db.execute(
      'CREATE INDEX idx_banks_updated_at ON $tableBanks(updated_at)',
    );
    await db.execute(
      'CREATE INDEX idx_banks_source_file_name ON $tableBanks(source_file_name)',
    );

    await db.execute('''
CREATE TABLE $tableQuestions (
  id TEXT NOT NULL PRIMARY KEY,
  bank_id TEXT NOT NULL REFERENCES $tableBanks(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('single','multiple','judge','blank','short')),
  question TEXT NOT NULL,
  options_json TEXT,
  answer_json TEXT NOT NULL,
  explanation TEXT,
  option_explanations_json TEXT,
  tags_json TEXT,
  content_hash TEXT,
  answer_hash TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0
)''');
    await db.execute(
      'CREATE INDEX idx_questions_bank_order ON $tableQuestions(bank_id, sort_order)',
    );
    await db.execute(
      'CREATE INDEX idx_questions_content_hash ON $tableQuestions(content_hash)',
    );
    await db.execute(
      'CREATE INDEX idx_questions_bank_hash ON $tableQuestions(bank_id, content_hash)',
    );
    await db.execute(
      'CREATE INDEX idx_questions_bank_type ON $tableQuestions(bank_id, type)',
    );

    await db.execute('''
CREATE TABLE $tableRecords (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_id TEXT NOT NULL REFERENCES $tableBanks(id) ON DELETE CASCADE,
  question_id TEXT NOT NULL REFERENCES $tableQuestions(id) ON DELETE CASCADE,
  user_answer_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('correct','wrong','unanswered')),
  timestamp INTEGER NOT NULL
)''');
    await db.execute(
      'CREATE INDEX idx_records_bank_question ON $tableRecords(bank_id, question_id)',
    );
    await db.execute(
      'CREATE INDEX idx_records_question ON $tableRecords(question_id)',
    );
    await db.execute(
      'CREATE INDEX idx_records_timestamp ON $tableRecords(timestamp)',
    );

    await db.execute('''
CREATE TABLE $tableFavorites (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_id TEXT NOT NULL REFERENCES $tableBanks(id) ON DELETE CASCADE,
  question_id TEXT NOT NULL REFERENCES $tableQuestions(id) ON DELETE CASCADE,
  timestamp INTEGER NOT NULL,
  UNIQUE (bank_id, question_id)
)''');

    await db.execute('''
CREATE TABLE $tableWrongQuestions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_id TEXT NOT NULL REFERENCES $tableBanks(id) ON DELETE CASCADE,
  question_id TEXT NOT NULL REFERENCES $tableQuestions(id) ON DELETE CASCADE,
  first_wrong_at INTEGER NOT NULL,
  last_wrong_at INTEGER NOT NULL,
  wrong_count INTEGER NOT NULL DEFAULT 1,
  last_record_id INTEGER REFERENCES $tableRecords(id) ON DELETE SET NULL,
  UNIQUE (bank_id, question_id)
)''');
    await db.execute(
      'CREATE INDEX idx_wrong_bank_last ON $tableWrongQuestions(bank_id, last_wrong_at)',
    );

    await db.execute('''
CREATE TABLE $tablePracticeSessions (
  id TEXT NOT NULL PRIMARY KEY,
  bank_id TEXT NOT NULL REFERENCES $tableBanks(id) ON DELETE CASCADE,
  mode TEXT NOT NULL CHECK (mode IN ('sequential','random','wrong','favorite','exam')),
  type_filter TEXT,
  current_index INTEGER NOT NULL DEFAULT 0,
  question_ids_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)''');
    await db.execute(
      'CREATE INDEX idx_sessions_bank ON $tablePracticeSessions(bank_id)',
    );

    await db.execute('''
CREATE TABLE $tableSettings (
  key TEXT NOT NULL PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)''');

    await db.execute('''
CREATE TABLE $tableAiExplanations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_id TEXT NOT NULL REFERENCES $tableBanks(id) ON DELETE CASCADE,
  question_id TEXT NOT NULL REFERENCES $tableQuestions(id) ON DELETE CASCADE,
  explanation TEXT NOT NULL,
  model TEXT,
  created_at INTEGER NOT NULL
)''');
    await db.execute(
      'CREATE INDEX idx_ai_bank_question ON $tableAiExplanations(bank_id, question_id)',
    );
  }

  /// 逐级升级：对 `(oldVersion, newVersion]` 内每个版本执行登记的迁移。
  /// 缺少某一级迁移时抛 [ShuatiDatabaseException]（拒绝在未知状态上继续）。
  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion, {
    Map<int, ShuatiMigration>? migrationTable,
  }) async {
    final table = migrationTable ?? migrations;
    for (var v = oldVersion + 1; v <= newVersion; v++) {
      final step = table[v];
      if (step == null) {
        throw ShuatiDatabaseException('缺少 schema v$v 的迁移');
      }
      await step(db);
    }
  }
}

/// 打开 / 持有数据库。
class ShuatiDatabase {
  ShuatiDatabase._(this.db);

  /// 底层 sqflite 句柄。
  final Database db;

  /// 在应用文档目录下打开（或创建）`shuati.db`。
  static Future<ShuatiDatabase> openDefault() async {
    final dir = await getApplicationDocumentsDirectory();
    return open(path: p.join(dir.path, ShuatiSchema.fileName));
  }

  /// 打开指定路径（测试用 `inMemoryDatabasePath`）；[factory] 可注入
  /// `sqflite_common_ffi` 的 `databaseFactoryFfi`。
  ///
  /// [schemaVersion] / [migrationTable] 仅供迁移测试覆盖；生产调用保持默认。
  /// [singleInstance] 默认 `true`（同一路径复用同一连接，避免多连接写锁）；
  /// 测试里要同时开两个互不相干的内存库时传 `false`。
  static Future<ShuatiDatabase> open({
    required String path,
    DatabaseFactory? factory,
    int? schemaVersion,
    Map<int, ShuatiMigration>? migrationTable,
    bool singleInstance = true,
  }) async {
    final f = factory ?? databaseFactory;
    final target = schemaVersion ?? ShuatiSchema.version;
    try {
      final db = await f.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: target,
          singleInstance: singleInstance,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (db, version) async {
            await ShuatiSchema.create(db);
            // 测试用更高版本：建出 v1 后补跑到目标版本。
            if (version > ShuatiSchema.version) {
              await ShuatiSchema.upgrade(
                db,
                ShuatiSchema.version,
                version,
                migrationTable: migrationTable,
              );
            }
          },
          onUpgrade: (db, oldVersion, newVersion) => ShuatiSchema.upgrade(
            db,
            oldVersion,
            newVersion,
            migrationTable: migrationTable,
          ),
          onDowngrade: (db, oldVersion, newVersion) {
            // 绝不静默删库：新版本 App 写出的数据交给旧版本读会丢信息。
            throw ShuatiDatabaseException(
              '数据库版本 v$oldVersion 高于当前应用支持的 v$newVersion',
            );
          },
        ),
      );
      return ShuatiDatabase._(db);
    } on ShuatiDatabaseException {
      rethrow;
    } catch (error, stackTrace) {
      AppLogger.instance.log(
        LogLevel.error,
        LogCategory.storage,
        '刷题助手数据库打开失败',
        error: error,
        stackTrace: stackTrace,
      );
      throw const ShuatiDatabaseException('无法打开刷题助手数据库');
    }
  }

  Future<void> close() => db.close();
}
