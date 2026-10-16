import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/system_surface/widget_refresh_state.dart';

void main() {
  test('跨实例读取、损坏降级、旧结果不覆盖新记录', () async {
    final dir = await Directory.systemTemp.createTemp('widget_state_');
    try {
      final a = WidgetRefreshState(directory: () async => dir);
      final b = WidgetRefreshState(directory: () async => dir);
      expect(await a.load(), isNull);
      final first = DateTime(2026, 10, 15);
      await a.record(WidgetRefreshOutcome.ok, at: first);
      await b.record(
        WidgetRefreshOutcome.authFailed,
        at: first.add(const Duration(hours: 3)),
      );
      expect((await a.load())!.lastSuccessAt, first);
      await a.record(
        WidgetRefreshOutcome.ok,
        at: first.add(const Duration(hours: 1)),
      );
      expect((await b.load())!.lastOutcome, WidgetRefreshOutcome.authFailed);
      await File('${dir.path}/widget_refresh_state.json')
          .writeAsString('{broken');
      expect(await b.load(), isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
