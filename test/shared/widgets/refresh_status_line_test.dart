import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/refresh_status_line.dart';
import 'package:jxu_campus_hub/shared/widgets/skeleton_box.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  final now = DateTime(2026, 9, 30, 12);

  test('formatUpdatedAt omits the date on the same day', () {
    expect(
      RefreshStatusLine.formatUpdatedAt(DateTime(2026, 9, 30, 9, 5), now),
      '09:05',
    );
    expect(
      RefreshStatusLine.formatUpdatedAt(DateTime(2026, 9, 28, 21, 30), now),
      '9月28日 21:30',
    );
  });

  testWidgets('shows refreshing, failed and first-load labels', (tester) async {
    final updated = DateTime(2026, 9, 30, 10, 32);
    await tester.pumpWidget(_host(RefreshStatusLine(
      updatedAt: updated,
      refreshing: true,
      now: now,
    )));
    expect(find.text('10:32 更新 · 正在刷新'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(_host(RefreshStatusLine(
      updatedAt: updated,
      failed: true,
      now: now,
    )));
    expect(find.text('10:32 更新 · 刷新失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(_host(RefreshStatusLine(
      refreshing: true,
      loadingLabel: '正在获取电量…',
      now: now,
    )));
    expect(find.text('正在获取电量…'), findsOneWidget);
  });

  testWidgets('prefix is joined in front of the status text', (tester) async {
    final updated = DateTime(2026, 9, 30, 10, 32);
    await tester.pumpWidget(_host(RefreshStatusLine(
      updatedAt: updated,
      prefix: '67% · 满电 100 度',
      now: now,
    )));
    expect(find.text('67% · 满电 100 度 · 10:32 更新'), findsOneWidget);

    await tester.pumpWidget(_host(RefreshStatusLine(
      updatedAt: updated,
      prefix: '',
      now: now,
    )));
    expect(find.text('10:32 更新'), findsOneWidget);
  });

  testWidgets('refresh icon is disabled while refreshing', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(RefreshStatusLine(
      updatedAt: now,
      onRefresh: () => taps++,
      refreshTooltip: '刷新电量',
      now: now,
    )));
    await tester.tap(find.byTooltip('刷新电量'));
    expect(taps, 1);

    await tester.pumpWidget(_host(RefreshStatusLine(
      updatedAt: now,
      refreshing: true,
      onRefresh: () => taps++,
      refreshTooltip: '刷新电量',
      now: now,
    )));
    await tester.tap(find.byTooltip('刷新电量'), warnIfMissed: false);
    expect(taps, 1);
  });

  testWidgets('SkeletonBox settles (no infinite animation)', (tester) async {
    await tester.pumpWidget(_host(const SkeletonBox(width: 40, height: 20)));
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonBox), findsOneWidget);
  });
}
