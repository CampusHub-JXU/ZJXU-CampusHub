import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_model.dart';

void main() {
  test('parses a well-formed snapshot', () {
    final snapshot = PhysicalTestSnapshot.fromJson({
      'records': [
        {
          'academicYear': '2025-2026',
          'totalScore': 86.5,
          'grade': '良好',
          'items': [
            {'name': '50 米跑', 'result': '7.2 秒', 'score': 90, 'level': '优秀'},
          ],
        },
      ],
      'message': null,
      'updatedAt': '2026-09-12T10:00:00',
    });

    expect(snapshot.hasRecords, isTrue);
    expect(snapshot.updatedAt, DateTime(2026, 9, 12, 10));
    final record = snapshot.records.single;
    expect(record.academicYear, '2025-2026');
    expect(record.totalScore, '86.5');
    expect(record.grade, '良好');
    final item = record.items.single;
    expect(item.name, '50 米跑');
    expect(item.result, '7.2 秒');
    expect(item.score, '90');
    expect(item.level, '优秀');
  });

  test('missing or malformed fields never throw', () {
    final snapshot = PhysicalTestSnapshot.fromJson({
      'records': [
        {
          'items': [
            null,
            42,
            {'name': 123},
          ],
        },
      ],
      'updatedAt': 'not-a-date',
    });

    expect(snapshot.hasRecords, isTrue);
    expect(snapshot.updatedAt, isNull);
    final record = snapshot.records.single;
    expect(record.academicYear, '');
    expect(record.totalScore, '');
    expect(record.grade, '');
    final item = record.items.single;
    expect(item.name, '123');
    expect(item.result, '');
    expect(item.score, '');
    expect(item.level, '');
  });

  test('non-list records degrade to an empty snapshot', () {
    final snapshot = PhysicalTestSnapshot.fromJson({'records': 'bad'});

    expect(snapshot.hasRecords, isFalse);
    expect(snapshot.message, isNull);
  });
}
