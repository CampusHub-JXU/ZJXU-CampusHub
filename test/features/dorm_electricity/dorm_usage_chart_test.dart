import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/theme.dart';
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
                refreshFailed: false,
                backgroundAvailable: true,
                onBackgroundChanged: (value) => changed = value,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('用电趋势（本地采样）'), findsOneWidget);
    expect(find.text('-- W'), findsOneWidget);
    expect(find.text('需两次成功查询，间隔 10 分钟～3 小时'), findsOneWidget);
    expect(find.text('后台用电监测'), findsOneWidget);
    final monitoringSwitch = find.byType(Switch).first;
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
    Future<void> pump(bool failed, {bool currentIntervalValid = true}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  DormUsageChart(
                    points: points,
                    currentIntervalValid: currentIntervalValid,
                    refreshFailed: failed,
                  ),
                ],
              ),
            ),
          ),
        );
    await pump(false);
    expect(find.text('360 W'), findsOneWidget);
    expect(find.text('24小时(W)'), findsOneWidget);
    await pump(true);
    expect(find.text('-- W'), findsOneWidget);
    expect(find.text('刷新失败，历史记录不代表当前功率'), findsOneWidget);
    await pump(false, currentIntervalValid: false);
    expect(find.text('-- W'), findsOneWidget);
    expect(find.text('等待间隔 10 分钟以上的下次采样'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'supports range switching, interactive tooltip selection and resets on switch',
    (tester) async {
      final now = DateTime.now();
      final points = <DormUsagePoint>[
        for (var i = 20; i >= 2; i--)
          DormUsagePoint(
            startedAt: now.subtract(Duration(hours: i)),
            endedAt: now.subtract(Duration(hours: i - 1)),
            consumedKwh: 0.25,
          ),
        DormUsagePoint(
          startedAt: now.subtract(const Duration(hours: 1)),
          endedAt: now,
          consumedKwh: 0.312,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: ListView(
              children: [
                DormUsageChart(
                  points: points,
                  remainingKwh: 46.8,
                  refreshFailed: false,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('用电趋势（本地采样）'), findsOneWidget);
      expect(find.textContaining('覆盖 '), findsOneWidget);
      expect(find.textContaining('约可用 '), findsOneWidget);
      expect(find.text('点按或滑动曲线查看读数'), findsOneWidget);

      // Tap chart to select a middle point and verify tooltip appears inside chart bounds.
      final chartFinder = find.bySemanticsLabel(RegExp(r'用电趋势折线图'));
      expect(chartFinder, findsOneWidget);
      final chartBox = tester.getRect(chartFinder);
      await tester.tapAt(Offset(chartBox.center.dx, chartBox.center.dy));
      await tester.pump();

      expect(find.text('点按或滑动曲线查看读数'), findsNothing);
      final tooltipFinder = find.textContaining('· 250 W');
      expect(tooltipFinder, findsOneWidget);
      final tooltipRect = tester.getRect(tooltipFinder);
      expect(tooltipRect.left, greaterThanOrEqualTo(chartBox.left));
      expect(tooltipRect.right, lessThanOrEqualTo(chartBox.right));

      // Drag to the far right edge and verify tooltip updates & stays inside bounds.
      await tester.dragFrom(
        Offset(chartBox.center.dx, chartBox.center.dy),
        Offset(chartBox.width * 0.48, 0),
      );
      await tester.pump();
      final rightTooltip = find.textContaining('· 312 W');
      expect(rightTooltip, findsOneWidget);
      final rightRect = tester.getRect(rightTooltip);
      expect(rightRect.left, greaterThanOrEqualTo(chartBox.left));
      expect(rightRect.right, lessThanOrEqualTo(chartBox.right));

      // Switch range -> selection resets and 7-day metric is shown.
      await tester.tap(find.text('近7日(度)'));
      await tester.pumpAndSettle();
      expect(find.text('点按或滑动曲线查看读数'), findsOneWidget);
      expect(find.text('近 7 日累计'), findsOneWidget);

      // Switch to 30-day range.
      await tester.tap(find.text('近30日(度)'));
      await tester.pumpAndSettle();
      expect(find.text('近 30 日累计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'does not overflow on 360dp narrow screen with scaled text and dark theme',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final now = DateTime.now();
      final points = [
        // Gap between earlier point and recent points.
        DormUsagePoint(
          startedAt: now.subtract(const Duration(hours: 22)),
          endedAt: now.subtract(const Duration(hours: 21)),
          consumedKwh: 0.30,
        ),
        DormUsagePoint(
          startedAt: now.subtract(const Duration(hours: 3)),
          endedAt: now.subtract(const Duration(hours: 2)),
          consumedKwh: 0.24,
        ),
        DormUsagePoint(
          startedAt: now.subtract(const Duration(hours: 2)),
          endedAt: now.subtract(const Duration(hours: 1)),
          consumedKwh: 0.31,
        ),
        DormUsagePoint(
          startedAt: now.subtract(const Duration(hours: 1)),
          endedAt: now,
          consumedKwh: 0.248,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              textScaler: TextScaler.linear(1.4),
            ),
            child: Scaffold(
              body: ListView(
                children: [
                  DormUsageChart(
                    points: points,
                    remainingKwh: 46.8,
                    refreshFailed: false,
                    backgroundAvailable: true,
                    backgroundEnabled: true,
                    onBackgroundChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('248 W'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
