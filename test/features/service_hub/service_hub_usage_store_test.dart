import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/config/service_hub_usage_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceHubUsageStore.instance.debugReset();
  });

  tearDown(() {
    ServiceHubUsageStore.instance.debugReset();
  });

  test('keeps at most six pinned entries and removes oldest', () async {
    final store = ServiceHubUsageStore.instance;

    for (final id in [
      'schedule',
      'grades',
      'exam',
      'shuati-practice',
      'library',
      'campus-card',
      'service-hall',
    ]) {
      await store.togglePinned(id);
    }

    expect(store.snapshot.pinnedIds, [
      'grades',
      'exam',
      'shuati-practice',
      'library',
      'campus-card',
      'service-hall',
    ]);
  });

  test('records visit count and last visited time', () async {
    final store = ServiceHubUsageStore.instance;
    final firstVisit = DateTime(2026, 6, 9, 8);
    final secondVisit = DateTime(2026, 6, 9, 9);

    await store.recordVisit('grades', now: firstVisit);
    await store.recordVisit('grades', now: secondVisit);

    final entry = store.snapshot.usageById['grades'];
    expect(entry, isNotNull);
    expect(entry!.visitCount, 2);
    expect(entry.lastVisitedAt, secondVisit);
  });
}
