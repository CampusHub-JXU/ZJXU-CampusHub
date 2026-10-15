import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/shared/widgets/app_tile_surface.dart';
import 'package:jxu_campus_hub/shared/widgets/detail_readout.dart';

Widget _host(Widget child, {ThemeData? theme, double textScale = 1}) {
  return MaterialApp(
    theme: theme ?? AppTheme.lightTheme,
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
}

/// 「减弱动效」宿主：系统要求移除动画时 [DetailLevelBar] 必须直接到位。
Widget _reduceHost(double fraction) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Scaffold(
        body: SizedBox(width: 200, child: DetailLevelBar(fraction: fraction)),
      ),
    ),
  );
}

double? _barFactor(WidgetTester tester) {
  return tester
      .widget<FractionallySizedBox>(
        find.descendant(
          of: find.byType(DetailLevelBar),
          matching: find.byType(FractionallySizedBox),
        ),
      )
      .widthFactor;
}

void main() {
  testWidgets('readout puts the unit after the number and mutes placeholders', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const DetailReadout(
          label: '校园卡余额',
          valueText: '128.50',
          unit: '元',
          trailing: Text('尾部'),
        ),
      ),
    );
    final cs = Theme.of(tester.element(find.text('128.50'))).colorScheme;
    expect(find.text('校园卡余额'), findsOneWidget);
    expect(find.text('尾部'), findsOneWidget);
    expect(
      tester.getRect(find.text('元')).left,
      greaterThan(tester.getRect(find.text('128.50')).right),
    );
    expect(tester.widget<Text>(find.text('128.50')).style?.color, cs.onSurface);

    await tester.pumpWidget(
      _host(
        const DetailReadout(
          label: '校园卡余额',
          valueText: '--',
          unit: '元',
          muted: true,
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('--')).style?.color,
      cs.outlineVariant,
    );
  });

  testWidgets('readout scales a long number down instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        const DetailReadout(label: '校园卡余额', valueText: '12345.67', unit: '元'),
        textScale: 1.5,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.text('元')).right,
      lessThanOrEqualTo(320 - 16 + 0.01),
    );
  });

  testWidgets('level bar settles on the clamped fraction, no looping motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 200, child: DetailLevelBar(fraction: 0.25))),
    );
    // 没有循环动画：pumpAndSettle 必须能结束。
    await tester.pumpAndSettle();
    expect(_barFactor(tester), closeTo(0.25, 1e-9));
    expect(tester.getSize(find.byType(DetailLevelBar)).height, 6);

    await tester.pumpWidget(
      _host(const SizedBox(width: 200, child: DetailLevelBar(fraction: 1.7))),
    );
    await tester.pumpAndSettle();
    expect(_barFactor(tester), 1.0);
  });

  testWidgets('level bar jumps straight to the value when motion is reduced', (
    tester,
  ) async {
    await tester.pumpWidget(_reduceHost(0.6));
    await tester.pump();
    expect(_barFactor(tester), closeTo(0.6, 1e-9));
  });

  // ── Issue #62：进详情不再重播 0→缓存值 ──────────────────────────────────

  testWidgets('level bar draws the target on the first frame, never 0', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 200, child: DetailLevelBar(fraction: 0.7))),
    );
    // 未经过任何动画帧：首帧宽度即为目标，而不是从 0 起手。
    expect(_barFactor(tester), closeTo(0.7, 1e-9));
    await tester.pumpAndSettle();
    expect(_barFactor(tester), closeTo(0.7, 1e-9));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('remounting the same value never replays 0→target', (
    tester,
  ) async {
    // 模拟详情页反复 push / pop（重挂载）、旋转、主题切换：每次都必须是目标宽度。
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(
        _host(
          const SizedBox(width: 200, child: DetailLevelBar(fraction: 0.42)),
        ),
      );
      expect(_barFactor(tester), closeTo(0.42, 1e-9));
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('a real value change transitions from the current width, not 0', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 200, child: DetailLevelBar(fraction: 0.3))),
    );
    expect(_barFactor(tester), closeTo(0.3, 1e-9));

    await tester.pumpWidget(
      _host(const SizedBox(width: 200, child: DetailLevelBar(fraction: 0.8))),
    );
    // 起手仍是旧宽度（从当前长度出发），不是 0。
    expect(_barFactor(tester), closeTo(0.3, 1e-9));

    await tester.pump(const Duration(milliseconds: 150));
    final mid = _barFactor(tester)!;
    expect(mid, greaterThan(0.3));
    expect(mid, lessThan(0.8));

    await tester.pumpAndSettle();
    expect(_barFactor(tester), closeTo(0.8, 1e-9));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('refreshing with the same value starts no animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 200, child: DetailLevelBar(fraction: 0.5))),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(const SizedBox(width: 200, child: DetailLevelBar(fraction: 0.5))),
    );
    expect(_barFactor(tester), closeTo(0.5, 1e-9));
    // 同值刷新不建动画：没有活动的 ticker，也没有待调度帧。
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion jumps straight on a real value change too', (
    tester,
  ) async {
    await tester.pumpWidget(_reduceHost(0.2));
    expect(_barFactor(tester), closeTo(0.2, 1e-9));

    await tester.pumpWidget(_reduceHost(0.9));
    // 变化瞬时到位，且完全不建动画控制器。
    expect(_barFactor(tester), closeTo(0.9, 1e-9));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('action grid: equal tiles, primary follows theme, taps fire', (
    tester,
  ) async {
    final taps = <String>[];
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    );
    await tester.pumpWidget(
      _host(
        DetailActionGrid(
          actions: [
            DetailAction(
              icon: Icons.qr_code_2_outlined,
              title: '付款码',
              subtitle: '出示扫码',
              onTap: () => taps.add('pay'),
              primary: true,
            ),
            DetailAction(
              icon: Icons.receipt_long_outlined,
              title: '账单',
              subtitle: '消费明细',
              onTap: () => taps.add('bill'),
            ),
            DetailAction(
              icon: Icons.add_card_outlined,
              title: '充值',
              subtitle: '微信',
              onTap: () => taps.add('recharge'),
            ),
          ],
        ),
        theme: theme,
      ),
    );
    await tester.pump();

    final primaryMaterial = tester.widget<Material>(
      find
          .ancestor(of: find.text('付款码'), matching: find.byType(Material))
          .first,
    );
    expect(primaryMaterial.color, theme.colorScheme.primary);
    expect(find.byType(AppTileSurface), findsNWidgets(2));

    final sizes = [
      for (final title in ['付款码', '账单', '充值'])
        tester.getSize(
          find
              .ancestor(of: find.text(title), matching: find.byType(Expanded))
              .first,
        ),
    ];
    expect(sizes[0].width, closeTo(sizes[1].width, 0.01));
    expect(sizes[1].width, closeTo(sizes[2].width, 0.01));
    expect(sizes.map((s) => s.height).toSet(), hasLength(1));
    expect(sizes.first.height, greaterThanOrEqualTo(104));

    await tester.tap(find.text('付款码'));
    await tester.tap(find.text('账单'));
    await tester.tap(find.text('充值'));
    expect(taps, ['pay', 'bill', 'recharge']);

    expect(find.bySemanticsLabel('付款码，出示扫码'), findsOneWidget);
    expect(find.bySemanticsLabel('充值，微信'), findsOneWidget);
  });

  testWidgets('action grid survives 1.5x text on a 360px screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        DetailActionGrid(
          actions: [
            DetailAction(
              icon: Icons.account_balance_wallet_outlined,
              title: '充值',
              subtitle: '微信',
              onTap: () {},
              primary: true,
            ),
            DetailAction(
              icon: Icons.notifications_outlined,
              title: '低电提醒',
              subtitle: '低于 20 度',
              onTap: () {},
            ),
            DetailAction(
              icon: Icons.home_outlined,
              title: '寝室',
              subtitle: '点按更换',
              onTap: () {},
            ),
          ],
        ),
        textScale: 1.5,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
