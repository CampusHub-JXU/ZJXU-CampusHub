import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_usage_chart.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_usage_history.dart';

void main() {
  testWidgets('empty chart shows no fabricated estimate and can opt in', (
    tester,
  ) async {
    bool? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              DormUsageChart(
                points: const [],
                monitoring: false,
                canMonitor: true,
                refreshFailed: false,
                onMonitoringChanged: (value) => changed = value,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('-- W'), findsOneWidget);
    expect(find.text('需两次成功查询，间隔10～30分钟'), findsOneWidget);
    final monitoringSwitch = find.byType(SwitchListTile).first;
    await tester.ensureVisible(monitoringSwitch);
    await tester.pumpAndSettle();
    await tester.tap(monitoringSwitch);
    expect(changed, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('renders real interval and suppresses current value on failure', (
    tester,
  ) async {
    final now = DateTime.now();
    final points = [
      DormUsagePoint(
        startedAt: now.subtract(const Duration(minutes: 10)),
        endedAt: now,
        consumedKwh: 0.06,
      ),
    ];
    Future<void> pump(bool failed) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              DormUsageChart(
                points: points,
                monitoring: false,
                canMonitor: true,
                refreshFailed: failed,
                onMonitoringChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await pump(false);
    expect(find.text('360 W'), findsOneWidget);
    expect(find.text('近24小时耗电趋势（W）'), findsOneWidget);
    await pump(true);
    expect(find.text('-- W'), findsOneWidget);
    expect(find.text('刷新失败，历史记录不代表当前功率'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
