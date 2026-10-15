import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码级守卫（非设备证明）：Issue #48 的只读扫描必须保持纯读，
/// 清理必须按精确三元组删除、绝不 `clearAll`。
void main() {
  final nativeStore = File(
    'android/app/src/main/kotlin/edu/zjxu/jxucampushub/platform/calendar/'
    'CalendarProviderStore.kt',
  ).readAsStringSync();
  final control = File('lib/core/calendar/calendar_sync_control.dart')
      .readAsStringSync();

  String methodBody(String source, String name) {
    final start = source.indexOf('fun $name(');
    expect(start, greaterThanOrEqualTo(0), reason: '缺少方法 $name');
    final next = source.indexOf('fun ', start + 1);
    return next < 0 ? source.substring(start) : source.substring(start, next);
  }

  test('原生只读发现方法不含任何写操作', () {
    for (final name in <String>['listOwnedEventCalendars', 'scanOwnedEvents']) {
      final body = methodBody(nativeStore, name);
      for (final forbidden in <String>[
        'resolver.insert',
        'resolver.update',
        'resolver.delete',
        'applyBatch',
        'createOrGetLocalCalendar',
      ]) {
        expect(
          body.contains(forbidden),
          isFalse,
          reason: '$name 不得包含写操作 $forbidden',
        );
      }
    }
  });

  test('原生删除仍限定 _id + calendar_id + package + URI 四元组', () {
    final start = nativeStore.indexOf('fun deleteOwnedEventsByIds(');
    expect(start, greaterThanOrEqualTo(0));
    final body = methodBody(nativeStore, 'deleteOwnedEventsByIds');
    expect(body.contains('EVENT_OWNER_SELECTION'), isTrue);
  });

  test('Dart 遗留清理绝不调用 clearAll', () {
    final start = control.indexOf(
      'Future<CalendarLegacyCleanupResult> cleanupLegacyOwnedEvents(',
    );
    expect(start, greaterThanOrEqualTo(0));
    final end = control.indexOf('Future<void> dismissLegacyCleanupPreview(');
    expect(end, greaterThan(start));
    final body = control.substring(start, end);
    expect(body.contains('clearAll'), isFalse);
  });
}
