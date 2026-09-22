import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('PrivateCacheEnvelope', () {
    test('round trips owner / updatedAt / epoch / payload', () {
      final envelope = PrivateCacheEnvelope(
        owner: '2025000001',
        updatedAt: DateTime(2026, 9, 22, 10, 30),
        epoch: 7,
        payload: [
          {'kcmc': '高等数学', 'jd': '4.0'},
        ],
      );

      final decoded = PrivateCacheEnvelope.tryDecode(envelope.encode());

      expect(decoded, isNotNull);
      expect(decoded!.owner, '2025000001');
      expect(decoded.updatedAt, DateTime(2026, 9, 22, 10, 30));
      expect(decoded.epoch, 7);
      expect(decoded.belongsTo('2025000001', 7), isTrue);
      expect(decoded.belongsTo('2025000001', 8), isFalse);
      expect(decoded.belongsTo('other', 7), isFalse);
      expect(decoded.payload, [
        {'kcmc': '高等数学', 'jd': '4.0'},
      ]);
    });

    test(
      'rejects malformed / ownerless / timestamp-less / epoch-less records',
      () {
        expect(PrivateCacheEnvelope.tryDecode(null), isNull);
        expect(PrivateCacheEnvelope.tryDecode(''), isNull);
        expect(PrivateCacheEnvelope.tryDecode('not-json'), isNull);
        expect(PrivateCacheEnvelope.tryDecode('[1,2,3]'), isNull);
        // 旧 v1（无 epoch）不得被当作当前纪元记录。
        expect(
          PrivateCacheEnvelope.tryDecode(
            jsonEncode({
              'v': 1,
              'owner': 'A',
              'updatedAt': '2026-09-22T00:00:00.000',
              'payload': 1,
            }),
          ),
          isNull,
        );
        expect(
          PrivateCacheEnvelope.tryDecode(
            jsonEncode({
              'v': 2,
              'owner': 'A',
              'updatedAt': '2026-09-22T00:00:00.000',
              'payload': 1,
            }),
          ),
          isNull,
        );
        expect(
          PrivateCacheEnvelope.tryDecode(
            jsonEncode({
              'v': 2,
              'updatedAt': '2026-09-22T00:00:00.000',
              'epoch': 1,
              'payload': 1,
            }),
          ),
          isNull,
        );
        expect(
          PrivateCacheEnvelope.tryDecode(
            jsonEncode({'v': 2, 'owner': 'A', 'epoch': 1, 'payload': 1}),
          ),
          isNull,
        );
        expect(
          PrivateCacheEnvelope.tryDecode(
            jsonEncode({
              'v': 99,
              'owner': 'A',
              'updatedAt': '2026-09-22T00:00:00.000',
              'epoch': 1,
            }),
          ),
          isNull,
        );
      },
    );
  });

  group('SharedPreferencesPrivateCacheStore', () {
    test('write / read / clear round trip', () async {
      final store = SharedPreferencesPrivateCacheStore('test_private_cache_v1');
      expect(await store.read(), isNull);

      await store.write(
        PrivateCacheEnvelope(
          owner: 'A',
          updatedAt: DateTime(2026, 1, 2),
          epoch: 3,
          payload: {'balance': 1.5},
        ),
      );

      final read = await store.read();
      expect(read, isNotNull);
      expect(read!.owner, 'A');
      expect(read.epoch, 3);

      await store.clear();
      expect(await store.read(), isNull);
    });

    test('concurrent writers never interleave into a mixed record', () async {
      final store = SharedPreferencesPrivateCacheStore('test_private_cache_v1');

      await Future.wait([
        store.write(
          PrivateCacheEnvelope(
            owner: 'A',
            updatedAt: DateTime(2026, 1, 1),
            epoch: 1,
            payload: List.generate(200, (i) => 'a$i'),
          ),
        ),
        store.write(
          PrivateCacheEnvelope(
            owner: 'B',
            updatedAt: DateTime(2026, 1, 2),
            epoch: 2,
            payload: List.generate(200, (i) => 'b$i'),
          ),
        ),
      ]);

      final read = await store.read();
      expect(read, isNotNull);
      // 只会是其中一条完整记录，不会是两次写入的混合。
      expect(read!.owner, anyOf('A', 'B'));
      expect(read.epoch, read.owner == 'A' ? 1 : 2);
      final payload = read.payload! as List<dynamic>;
      expect(payload, hasLength(200));
      final prefix = read.owner == 'A' ? 'a' : 'b';
      for (var i = 0; i < payload.length; i++) {
        expect(payload[i], '$prefix$i');
      }
    });
  });

  group('SecureStoragePrivateCacheStore', () {
    test('write / read / clear round trip', () async {
      final store = SecureStoragePrivateCacheStore(
        'test_secure_private_cache_v1',
      );
      expect(await store.read(), isNull);

      await store.write(
        PrivateCacheEnvelope(
          owner: 'casuser',
          updatedAt: DateTime(2026, 3, 4),
          epoch: 5,
          payload: 38.2,
        ),
      );

      final read = await store.read();
      expect(read, isNotNull);
      expect(read!.owner, 'casuser');
      expect(read.epoch, 5);
      expect(read.payload, 38.2);

      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
