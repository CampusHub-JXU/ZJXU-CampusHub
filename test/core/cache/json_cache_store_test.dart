import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/cache/json_cache_store.dart';

import '../../helpers/test_setup.dart';

void main() {
  Directory? tempDir;
  late JsonCacheStore store;
  late File Function(String bucket) bucketFile;

  setUp(() async {
    await resetTestEnvironment();
    store = JsonCacheStore.instance;
    tempDir = await Directory.systemTemp.createTemp('json_cache_store_test');
    JsonCacheStore.instance.debugDirectoryProvider = () async => tempDir!;
    bucketFile = (String bucket) => File(
      <String>[
        tempDir!.path,
        'json_cache',
        '$bucket.json',
      ].join(Platform.pathSeparator),
    );
  });

  tearDown(() async {
    await JsonCacheStore.instance.debugClear();
    JsonCacheStore.instance.debugReset();
    tempDir?.deleteSync(recursive: true);
    tempDir = null;
  });

  // 预热桶：让内存镜像先建立，便于区分「加载竞态」与「写入排队」两类行为。
  Future<void> warmBucket(String bucket) => store.read(bucket, '__warm__');

  group('读写往返', () {
    test('未命中返回 null', () async {
      expect(await store.read('dorm', 'rooms'), isNull);
    });

    test('write 之后可原样读回', () async {
      final written = DateTime.now();
      await store.write('dorm', 'rooms', <String, dynamic>{
        'list': [1, 2, 3],
        'name': '寝室目录',
      });

      final record = await store.read('dorm', 'rooms');

      expect(record, isNotNull);
      expect(record!.payload, <String, dynamic>{
        'list': [1, 2, 3],
        'name': '寝室目录',
      });
      expect(
        record.updatedAt.difference(written).abs(),
        lessThan(const Duration(seconds: 5)),
      );
    });

    test('write 支持显式指定 updatedAt', () async {
      final at = DateTime.now().subtract(const Duration(hours: 9));
      await store.write('dorm', 'rooms', 'old', updatedAt: at);

      final record = await store.read('dorm', 'rooms');

      expect(record!.updatedAt, at);
      expect(record.payload, 'old');
    });

    test('同 bucket 同 key 覆盖写入只保留最新值', () async {
      await store.write('balance', 'card', 12.5);
      await store.write('balance', 'card', 30.0);

      expect((await store.read('balance', 'card'))!.payload, 30.0);
    });

    test('同 bucket 不同 key 互不干扰', () async {
      await store.write('balance', 'card', 12.5);
      await store.write('balance', 'coupon', 3);

      expect((await store.read('balance', 'card'))!.payload, 12.5);
      expect((await store.read('balance', 'coupon'))!.payload, 3);
    });

    test('不同 bucket 相互隔离且各自落一个 json 文件', () async {
      await store.write('dorm', 'rooms', 'A');
      await store.write('balance', 'card', 'B');

      expect((await store.read('dorm', 'rooms'))!.payload, 'A');
      expect((await store.read('balance', 'card'))!.payload, 'B');
      expect(await store.read('balance', 'rooms'), isNull);
      expect(await bucketFile('dorm').exists(), isTrue);
      expect(await bucketFile('balance').exists(), isTrue);
    });
  });

  group('落盘格式', () {
    test('文件内容为 {v: schemaVersion, entries: {...}}', () async {
      final at = DateTime(2026, 8, 31, 10, 30);
      await store.write('dorm', 'rooms', <String, dynamic>{
        'n': 1,
      }, updatedAt: at);

      final raw = jsonDecode(await bucketFile('dorm').readAsString());

      expect(raw, isA<Map<String, dynamic>>());
      expect(raw['v'], JsonCacheStore.schemaVersion);
      final entries = raw['entries'] as Map<String, dynamic>;
      expect(entries.keys, ['rooms']);
      expect(entries['rooms']['payload'], <String, dynamic>{'n': 1});
      expect(entries['rooms']['updatedAt'], at.toIso8601String());
    });

    test('内存镜像清空后可从磁盘重新加载', () async {
      await store.write('dorm', 'rooms', <String, dynamic>{'n': 1});

      JsonCacheStore.instance.debugReset();
      JsonCacheStore.instance.debugDirectoryProvider = () async => tempDir!;

      final record = await store.read('dorm', 'rooms');

      expect(record, isNotNull);
      expect(record!.payload, <String, dynamic>{'n': 1});
    });
  });

  group('删除', () {
    test('remove 只删指定 key，同桶其它条目保留', () async {
      await store.write('dorm', 'rooms', 'A');
      await store.write('dorm', 'buildings', 'B');

      await store.remove('dorm', 'rooms');

      expect(await store.read('dorm', 'rooms'), isNull);
      expect((await store.read('dorm', 'buildings'))!.payload, 'B');
    });

    test('remove 不存在的 key 不产生落盘', () async {
      await store.remove('brand-new-bucket', 'missing');

      expect(await bucketFile('brand-new-bucket').exists(), isFalse);
    });

    test('clearBucket 清空整桶', () async {
      await store.write('dorm', 'rooms', 'A');
      await store.write('dorm', 'buildings', 'B');

      await store.clearBucket('dorm');

      expect(await store.read('dorm', 'rooms'), isNull);
      expect(await store.read('dorm', 'buildings'), isNull);
      expect(
        (jsonDecode(await bucketFile('dorm').readAsString())
            as Map<String, dynamic>)['entries'],
        isEmpty,
      );
    });

    test('clearBucket 不影响其它桶', () async {
      await store.write('dorm', 'rooms', 'A');
      await store.write('balance', 'card', 'B');

      await store.clearBucket('dorm');

      expect((await store.read('balance', 'card'))!.payload, 'B');
    });

    test('clearAll 清空全部桶并删除落盘文件', () async {
      await store.write('dorm', 'rooms', 'A');
      await store.write('balance', 'card', 'B');

      await store.clearAll();

      expect(await store.read('dorm', 'rooms'), isNull);
      expect(await store.read('balance', 'card'), isNull);
      expect(await bucketFile('dorm').exists(), isFalse);
      expect(await bucketFile('balance').exists(), isFalse);
    });
  });

  group('损坏与版本不兼容时整桶丢弃', () {
    test('JSON 解析失败时返回 null 并删除文件', () async {
      await bucketFile('dorm').create(recursive: true);
      await bucketFile('dorm').writeAsString('{ 这不是 json');

      expect(await store.read('dorm', 'rooms'), isNull);
      expect(await bucketFile('dorm').exists(), isFalse);
    });

    test('schemaVersion 低于当前值时整桶作废', () async {
      await bucketFile('dorm').create(recursive: true);
      await bucketFile('dorm').writeAsString(
        jsonEncode(<String, dynamic>{
          'v': JsonCacheStore.schemaVersion - 1,
          'entries': <String, dynamic>{
            'rooms': <String, dynamic>{
              'updatedAt': DateTime.now().toIso8601String(),
              'payload': 'A',
            },
          },
        }),
      );

      expect(await store.read('dorm', 'rooms'), isNull);
      expect(await bucketFile('dorm').exists(), isFalse);
    });

    test('schemaVersion 高于当前值时整桶作废', () async {
      await bucketFile('dorm').create(recursive: true);
      await bucketFile('dorm').writeAsString(
        jsonEncode(<String, dynamic>{
          'v': JsonCacheStore.schemaVersion + 1,
          'entries': <String, dynamic>{
            'rooms': <String, dynamic>{
              'updatedAt': DateTime.now().toIso8601String(),
              'payload': 'A',
            },
          },
        }),
      );

      expect(await store.read('dorm', 'rooms'), isNull);
      expect(await bucketFile('dorm').exists(), isFalse);
    });

    test('缺少 v 字段时整桶作废', () async {
      await bucketFile('dorm').create(recursive: true);
      await bucketFile('dorm').writeAsString(
        jsonEncode(<String, dynamic>{'entries': <String, dynamic>{}}),
      );

      expect(await store.read('dorm', 'rooms'), isNull);
      expect(await bucketFile('dorm').exists(), isFalse);
    });

    test('顶层不是 Map 时整桶作废', () async {
      await bucketFile('dorm').create(recursive: true);
      await bucketFile('dorm').writeAsString('[1, 2, 3]');

      expect(await store.read('dorm', 'rooms'), isNull);
      expect(await bucketFile('dorm').exists(), isFalse);
    });

    test('entries 不是 Map 时按空桶加载', () async {
      await bucketFile('dorm').create(recursive: true);
      await bucketFile('dorm').writeAsString(
        jsonEncode(<String, dynamic>{
          'v': JsonCacheStore.schemaVersion,
          'entries': <dynamic>[],
        }),
      );

      expect(await store.read('dorm', 'rooms'), isNull);
    });
  });

  group('单条记录损坏', () {
    test('updatedAt 不可解析的条目被跳过，其余条目保留', () async {
      await bucketFile('dorm').create(recursive: true);
      await bucketFile('dorm').writeAsString(
        jsonEncode(<String, dynamic>{
          'v': JsonCacheStore.schemaVersion,
          'entries': <String, dynamic>{
            'ok': <String, dynamic>{
              'updatedAt': DateTime.now().toIso8601String(),
              'payload': 'A',
            },
            'bad-time': <String, dynamic>{
              'updatedAt': 'not-a-date',
              'payload': 'B',
            },
            'not-a-map': 42,
          },
        }),
      );

      expect((await store.read('dorm', 'ok'))!.payload, 'A');
      expect(await store.read('dorm', 'bad-time'), isNull);
      expect(await store.read('dorm', 'not-a-map'), isNull);
    });
  });

  group('并发', () {
    test('冷启动时同一 bucket 的并发写入全部生效', () async {
      await Future.wait(<Future<void>>[
        for (var i = 0; i < 20; i++) store.write('cold', 'k$i', i),
      ]);

      for (var i = 0; i < 20; i++) {
        expect((await store.read('cold', 'k$i'))!.payload, i, reason: 'k$i');
      }
    });

    test('同一 bucket 的并发写入全部生效', () async {
      await warmBucket('dorm');

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 20; i++) store.write('dorm', 'k$i', i),
      ]);

      for (var i = 0; i < 20; i++) {
        expect((await store.read('dorm', 'k$i'))!.payload, i, reason: 'k$i');
      }
      final entries =
          (jsonDecode(await bucketFile('dorm').readAsString())
                  as Map<String, dynamic>)['entries']
              as Map<String, dynamic>;
      expect(entries.length, 20);
    });

    test('不同 bucket 的并发写入互不干扰', () async {
      await warmBucket('dorm');
      await warmBucket('balance');

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 10; i++) store.write('dorm', 'k$i', i),
        for (var i = 0; i < 10; i++) store.write('balance', 'k$i', i * 10),
      ]);

      for (var i = 0; i < 10; i++) {
        expect((await store.read('dorm', 'k$i'))!.payload, i);
        expect((await store.read('balance', 'k$i'))!.payload, i * 10);
      }
    });
  });

  group('CacheRecord 序列化', () {
    test('toJson / fromJson 往返一致', () {
      final at = DateTime(2026, 8, 31, 10, 30);
      final record = CacheRecord(
        updatedAt: at,
        payload: <String, dynamic>{'a': 1},
      );

      final restored = CacheRecord.fromJson(record.toJson());

      expect(restored, isNotNull);
      expect(restored!.updatedAt, at);
      expect(restored.payload, <String, dynamic>{'a': 1});
    });

    test('fromJson 对非 Map 与坏时间一律返回 null', () {
      expect(CacheRecord.fromJson(42), isNull);
      expect(CacheRecord.fromJson(<String, dynamic>{}), isNull);
      expect(
        CacheRecord.fromJson(<String, dynamic>{'updatedAt': 'nope'}),
        isNull,
      );
    });
  });
}
