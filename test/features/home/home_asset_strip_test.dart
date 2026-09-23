import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_asset_strip.dart';

void main() {
  setUp(AppThemeController.instance.debugReset);

  HomeStatusPresentation statusOf({
    bool hasCampusCardData = true,
    bool hasElectricityData = true,
    bool lowElectricity = false,
  }) {
    return HomeStatusPresentation(
      campusCardBalance: '12.50',
      dormElectricity: '23.5',
      hasCampusCardData: hasCampusCardData,
      hasElectricityData: hasElectricityData,
      lowBalance: false,
      lowElectricity: lowElectricity,
    );
  }

  Future<void> pumpStrip(
    WidgetTester tester, {
    required HomeStatusPresentation status,
    VoidCallback? onCampusCardTap,
    VoidCallback? onElectricityTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeAssetStrip(
            status: status,
            onCampusCardTap: onCampusCardTap ?? () {},
            onElectricityTap: onElectricityTap ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('两区各暴露一个带 tap 动作的按钮语义节点', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpStrip(tester, status: statusOf());

    for (final label in <String>['校园卡余额 ¥12.50', '宿舍电费 23.5 度']) {
      final nodes = find.semantics.byLabel(label).evaluate();
      expect(nodes, hasLength(1), reason: '「$label」应只对应一个语义节点');
      final data = nodes.single.getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
    }

    // 子文本（标签 / 数值 / 后缀）不得另行成语义节点，避免重复播报。
    for (final label in <String>['校园卡', '¥12.50', '宿舍电费', '23.5 度']) {
      expect(
        find.semantics.byLabel(label).evaluate(),
        isEmpty,
        reason: '「$label」不应成为独立语义节点',
      );
    }
    expect(find.semantics.byLabel(RegExp('校园卡')).evaluate(), hasLength(1));
    expect(find.semantics.byLabel(RegExp('宿舍电费')).evaluate(), hasLength(1));
    handle.dispose();
  });

  testWidgets('校园卡语义 tap 只触发 onCampusCardTap', (tester) async {
    final handle = tester.ensureSemantics();
    final taps = <String>[];
    await pumpStrip(
      tester,
      status: statusOf(),
      onCampusCardTap: () => taps.add('card'),
      onElectricityTap: () => taps.add('power'),
    );

    // tester.semantics.tap 在节点缺少 tap 动作时直接抛错，兼作可激活性断言。
    tester.semantics.tap(find.semantics.byLabel('校园卡余额 ¥12.50'));
    await tester.pump();

    expect(taps, <String>['card']);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('宿舍电费语义 tap 只触发 onElectricityTap', (tester) async {
    final handle = tester.ensureSemantics();
    final taps = <String>[];
    await pumpStrip(
      tester,
      status: statusOf(),
      onCampusCardTap: () => taps.add('card'),
      onElectricityTap: () => taps.add('power'),
    );

    tester.semantics.tap(find.semantics.byLabel('宿舍电费 23.5 度'));
    await tester.pump();

    expect(taps, <String>['power']);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('真实点击两区仍各自触发对应回调', (tester) async {
    final taps = <String>[];
    await pumpStrip(
      tester,
      status: statusOf(),
      onCampusCardTap: () => taps.add('card'),
      onElectricityTap: () => taps.add('power'),
    );

    await tester.tap(find.text('校园卡'));
    await tester.tap(find.text('宿舍电费'));

    expect(taps, <String>['card', 'power']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未获取数据时保持未获取语义文案且仍可激活', (tester) async {
    final handle = tester.ensureSemantics();
    final taps = <String>[];
    await pumpStrip(
      tester,
      status: statusOf(hasCampusCardData: false, hasElectricityData: false),
      onCampusCardTap: () => taps.add('card'),
      onElectricityTap: () => taps.add('power'),
    );

    // 可见占位与语义文案都不改。
    expect(find.text('--'), findsNWidgets(2));

    final card = find.semantics.byLabel('校园卡余额未获取');
    final power = find.semantics.byLabel('宿舍电费未获取');
    expect(card.evaluate(), hasLength(1));
    expect(power.evaluate(), hasLength(1));

    tester.semantics.tap(card);
    tester.semantics.tap(power);
    await tester.pump();

    expect(taps, <String>['card', 'power']);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
}
