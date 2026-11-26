import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:jxu_campus_hub/features/settings/feedback_store.dart';
import 'package:jxu_campus_hub/features/settings/feedback_service.dart';

void main() {
  late Database db;
  late FeedbackStore store;
  const result = FeedbackSubmitResult(
    issueNumber: 42,
    issueUrl: 'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42',
  );
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => FeedbackStore.createSchema(db),
      ),
    );
    store = FeedbackStore(database: db);
  });
  tearDown(() async => db.close());

  test('draft survives store recreation; recording success atomically saves link and clears draft', () async {
    await store.setPreference('draft', '已有草稿');
    final second = FeedbackStore(database: db);
    expect(await second.preference('draft'), '已有草稿');
    await second.recordSubmission('成功标题', result);
    expect(await store.preference('draft'), isNull);
    final record = (await store.submissions()).single;
    expect(record['title'], '成功标题');
    expect(record['url'], result.issueUrl);
    await store.recordSubmission('同一 Issue', result);
    expect(await store.submissions(), hasLength(1));
  });
  test(
    'failed local history write preserves draft without fabricating a record',
    () async {
      await store.setPreference('draft', '必须保留');
      await db.execute(
        "CREATE TRIGGER fail_draft_delete BEFORE DELETE ON preferences BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
      );
      await expectLater(
        store.recordSubmission('标题', result),
        throwsA(anything),
      );
      expect(await store.preference('draft'), '必须保留');
      expect(await store.submissions(), isEmpty);
    },
  );
}
