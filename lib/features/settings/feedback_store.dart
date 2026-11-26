import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'feedback_service.dart';

/// Local drafts and confirmed GitHub links; no account, queue or remote cache.
class FeedbackStore {
  FeedbackStore({this._database});
  static final instance = FeedbackStore();
  Database? _database;
  Future<Database>? _opening;

  Future<Database> get database async =>
      _database ??= await (_opening ??= _open());

  Future<Database> _open() async {
    final directory = await getApplicationSupportDirectory();
    return openDatabase(
      p.join(directory.path, 'feedback_links.sqlite'),
      version: 1,
      onCreate: (db, _) => createSchema(db),
    );
  }

  static Future<void> createSchema(Database db) async {
    await db.execute('''CREATE TABLE submissions (
      url TEXT PRIMARY KEY, title TEXT NOT NULL, number INTEGER NOT NULL,
      created_at INTEGER NOT NULL)''');
    await db.execute(
      'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
  }

  Future<String?> preference(String key) async {
    final rows = await (await database).query(
      'preferences',
      where: 'key=?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<void> setPreference(String key, String? value) async {
    final db = await database;
    if (value == null) {
      await db.delete('preferences', where: 'key=?', whereArgs: [key]);
    } else {
      await db.insert('preferences', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> recordSubmission(
    String title,
    FeedbackSubmitResult result,
  ) async {
    await (await database).transaction((txn) async {
      await txn.insert('submissions', {
        'url': result.issueUrl,
        'title': title,
        'number': result.issueNumber,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('preferences', where: 'key=?', whereArgs: ['draft']);
    });
  }

  Future<List<Map<String, Object?>>> submissions() async =>
      (await database).query('submissions', orderBy: 'created_at DESC');
}
