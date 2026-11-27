import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_usage_history.dart';

void main() {
  final start = DateTime(2026, 11, 26, 9);
  DateTime at(int minute) => start.add(Duration(minutes: minute));

  test('0.06 kWh over ten minutes is 360 W', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.94, at(10));
    expect(h.points.single.watts, closeTo(360, .001));
  });
  test('short intervals retain baseline; duplicate ignored', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.99, at(5));
    expect(h.record(39.99, at(5)), isFalse);
    expect(h.points, isEmpty);
    h.record(39.94, at(10));
    expect(h.points.single.watts, closeTo(360, .001));
  });
  test('unchanged readings mean zero observed decrease', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(40, at(15));
    expect(h.points.single.watts, 0);
  });
  test('top-up breaks interval and preserves earlier observations', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.9, at(10));
    h.record(39.8, at(15));
    h.record(45, at(16));
    expect(h.points.length, 1);
    expect(h.hasCurrentInterval, isFalse);
    h.record(44.9, at(26));
    expect(h.points.length, 2);
    expect(h.points.last.watts, closeTo(600, .001));
    expect(h.hasCurrentInterval, isTrue);
  });
  test('long gap preserves earlier history; invalid and backwards ignored', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.9, at(10));
    h.record(39, at(45));
    expect(h.points.length, 1);
    expect(h.hasCurrentInterval, isFalse);
    expect(h.record(38.9, at(44)), isFalse);
    expect(h.record(double.nan, at(46)), isFalse);
    h.record(38.8, at(55));
    expect(h.points.length, 2);
  });
  test('observed totals account for gaps and prorate boundaries', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.8, at(20));
    h.record(39, at(60));
    h.record(38.8, at(80));
    final t = DormUsageHistory.total(h.points, at(10), at(70));
    expect(t.coverage, const Duration(minutes: 20));
    expect(t.kwh, closeTo(.2, .001));
    expect(
      DormUsageHistory.total(h.points, at(21), at(59)).coverage,
      Duration.zero,
    );
  });
  test('persisted points and baseline roundtrip, scope mismatch rejected', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.9, at(10));
    final restored = DormUsageHistory()
      ..restore(h.encode('A-room1'), 'A-room1', at(20));
    expect(restored.points.length, 1);
    restored.record(39.8, at(20));
    expect(restored.points.length, 2);
    restored.restore(h.encode('A-room1'), 'B-room1', at(20));
    expect(restored.points, isEmpty);
  });
  test('corrupt data and clock rollback rejected', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.9, at(10));
    final raw = h.encode('room');
    h.restore(raw, 'room', at(5));
    expect(h.points, isEmpty);
    h.restore('{oops', 'room', at(20));
    expect(h.points, isEmpty);
  });
  test('history retention and explicit reset', () {
    final h = DormUsageHistory();
    h.record(40, at(0));
    h.record(39.9, at(10));
    h.record(35, at(32 * 24 * 60));
    expect(h.points, isEmpty);
    h.clear();
    h.record(12, at(100));
    expect(h.points, isEmpty);
  });
}
