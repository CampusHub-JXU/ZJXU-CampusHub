import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/features/home/models/home_asset_state.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_asset_strip.dart';

void main() {
  setUp(AppThemeController.instance.debugReset);

  HomeStatusPresentation statusOf(
    HomeAssetState card,
    HomeAssetState electricity, {
    bool lowElectricity = false,
  }) {
    return HomeStatusPresentation(
      campusCardBalance: card.value ?? '--',
      dormElectricity: electricity.value ?? '--',
      hasCampusCardData: card.value != null,
      hasElectricityData: electricity.value != null,
      lowBalance: false,
      lowElectricity: lowElectricity,
      campusCardAsset: card,
      electricityAsset: electricity,
    );
  }

  Future<void> pumpStrip(
    WidgetTester tester, {
    required HomeStatusPresentation status,
    VoidCallback? onCampusCardTap,
    VoidCallback? onElectricityTap,
    VoidCallback? onCampusCardRetry,
    VoidCallback? onElectricityRetry,
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: MaterialApp(
          home: Scaffold(
            body: HomeAssetStrip(
              status: status,
              onCampusCardTap: onCampusCardTap ?? () {},
              onElectricityTap: onElectricityTap ?? () {},
              onCampusCardRetry: onCampusCardRetry,
              onElectricityRetry: onElectricityRetry,
            ),
          ),
        ),
      ),
    );
  }

  group('就绪态', () {
    testWidgets('两区各暴露一个带 tap 动作的按钮语义节点', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.ready('12.50'),
          const HomeAssetState.ready('23.5'),
        ),
      );

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
      handle.dispose();
    });

    testWidgets('语义 tap 只触发各自回调', (tester) async {
      final handle = tester.ensureSemantics();
      final taps = <String>[];
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.ready('12.50'),
          const HomeAssetState.ready('23.5'),
        ),
        onCampusCardTap: () => taps.add('card'),
        onElectricityTap: () => taps.add('power'),
      );

      tester.semantics.tap(find.semantics.byLabel('校园卡余额 ¥12.50'));
      tester.semantics.tap(find.semantics.byLabel('宿舍电费 23.5 度'));
      await tester.pump();

      expect(taps, <String>['card', 'power']);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('真实点击两区仍各自触发对应回调', (tester) async {
      final taps = <String>[];
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.ready('12.50'),
          const HomeAssetState.ready('23.5'),
        ),
        onCampusCardTap: () => taps.add('card'),
        onElectricityTap: () => taps.add('power'),
      );

      await tester.tap(find.text('校园卡'));
      await tester.tap(find.text('宿舍电费'));

      expect(taps, <String>['card', 'power']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('低电量用 error 色数值（双通道）', (tester) async {
      final cs = ThemeData.light().colorScheme;
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.ready('12.50'),
          const HomeAssetState.ready('3.2'),
          lowElectricity: true,
        ),
      );

      final low = tester.widget<Text>(find.text('3.2 度'));
      expect(low.style?.color, cs.error);
    });
  });

  group('获取中 / 刷新中', () {
    testWidgets('无缓存首次获取显示「获取中」+ 小转圈（真实在途）且不显示 --', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.loading(),
          const HomeAssetState.loading(),
        ),
      );

      expect(find.text('获取中'), findsNWidgets(2));
      expect(find.text('--'), findsNothing);
      // 真实首次获取（loading）也必须有「正在进行」的可见指示，不只靠文案。
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
      expect(find.semantics.byLabel('校园卡余额正在获取').evaluate(), hasLength(1));
      expect(find.semantics.byLabel('宿舍电费正在获取').evaluate(), hasLength(1));
      handle.dispose();
    });

    testWidgets('尚未发起请求的「准备中」（preparing）是静态文案，不转圈', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.preparing(),
          const HomeAssetState.preparing(),
        ),
      );

      // 还没真正请求：只给静态「获取中」，绝不画转圈（避免假装在跑）。
      expect(find.text('获取中'), findsNWidgets(2));
      expect(find.text('--'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.semantics.byLabel('校园卡余额正在获取').evaluate(), hasLength(1));
      handle.dispose();
    });

    testWidgets('两项独立：一项在途只该有它自己的转圈', (tester) async {
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.loading(),
          const HomeAssetState.ready('23.5'),
        ),
      );

      expect(find.text('获取中'), findsOneWidget);
      expect(find.text('23.5 度'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('有缓存后台刷新保留旧值并标注刷新中（不闪回占位符）', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.refreshing('12.50'),
          const HomeAssetState.refreshing('23.5'),
        ),
      );

      // 旧值仍在，旁边是小转圈，绝不出现 '--' / '获取中'。
      expect(find.text('¥12.50'), findsOneWidget);
      expect(find.text('23.5 度'), findsOneWidget);
      expect(find.text('获取中'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
      expect(
        find.semantics.byLabel('校园卡余额 ¥12.50，正在刷新').evaluate(),
        hasLength(1),
      );
      expect(
        find.semantics.byLabel('宿舍电费 23.5 度，正在刷新').evaluate(),
        hasLength(1),
      );
      handle.dispose();
    });

    testWidgets('系统「移除动画」时转圈降级为静态提示', (tester) async {
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.loading(),
          const HomeAssetState.refreshing('23.5'),
        ),
        disableAnimations: true,
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 静态文案仍表达状态。
      expect(find.text('获取中'), findsOneWidget);
      expect(find.text('23.5 度'), findsOneWidget);
    });
  });

  group('异常 / 待登录 / 未设置', () {
    testWidgets('未登录显示「待登录」而非未获取', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.waiting(),
          const HomeAssetState.waiting(),
        ),
      );

      expect(find.text('待登录'), findsNWidgets(2));
      expect(find.semantics.byLabel('校园卡余额待登录').evaluate(), hasLength(1));
      expect(find.semantics.byLabel('宿舍电费待登录').evaluate(), hasLength(1));
      handle.dispose();
    });

    testWidgets('冷启动恢复态显示「正在恢复」', (tester) async {
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.recovering(),
          const HomeAssetState.recovering(),
        ),
      );

      expect(find.text('正在恢复'), findsNWidgets(2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('电费未设置寝室显示「未设置」且语义准确', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.ready('12.50'),
          const HomeAssetState.notConfigured(),
        ),
      );

      expect(find.text('未设置'), findsOneWidget);
      expect(find.semantics.byLabel('宿舍电费未设置').evaluate(), hasLength(1));
      // 另一项不受影响。
      expect(find.text('¥12.50'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('获取失败无缓存时显示「获取失败」，点击触发受控重试而非导航', (tester) async {
      final handle = tester.ensureSemantics();
      final taps = <String>[];
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.error(),
          const HomeAssetState.error(),
        ),
        onCampusCardTap: () => taps.add('card-nav'),
        onElectricityTap: () => taps.add('power-nav'),
        onCampusCardRetry: () => taps.add('card-retry'),
        onElectricityRetry: () => taps.add('power-retry'),
      );

      expect(find.text('获取失败'), findsNWidgets(2));
      final card = find.semantics.byLabel('校园卡余额获取失败，点按重试');
      final power = find.semantics.byLabel('宿舍电费获取失败，点按重试');
      expect(card.evaluate(), hasLength(1));
      expect(power.evaluate(), hasLength(1));

      tester.semantics.tap(card);
      tester.semantics.tap(power);
      await tester.pump();

      expect(taps, <String>['card-retry', 'power-retry']);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('两项状态彼此独立：一项失败不影响另一项就绪', (tester) async {
      final taps = <String>[];
      await pumpStrip(
        tester,
        status: statusOf(
          const HomeAssetState.error(),
          const HomeAssetState.ready('23.5'),
        ),
        onCampusCardTap: () => taps.add('card-nav'),
        onCampusCardRetry: () => taps.add('card-retry'),
        onElectricityTap: () => taps.add('power-nav'),
      );

      // 失败项点击重试；就绪项仍导航。
      await tester.tap(find.text('获取失败'));
      await tester.tap(find.text('宿舍电费'));
      await tester.pump();

      expect(taps, <String>['card-retry', 'power-nav']);
    });
  });

  testWidgets('窄屏 360 / 深色 / 字号 2x：转圈与文案不溢出、行高稳定', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: HomeAssetStrip(
              status: statusOf(
                const HomeAssetState.loading(),
                const HomeAssetState.refreshing('1234.5'),
              ),
              onCampusCardTap: () {},
              onElectricityTap: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    // 高度稳定（≥ 既有 64 下限）、不超出视口宽度。
    final size = tester.getSize(find.byType(HomeAssetStrip));
    expect(size.height, greaterThanOrEqualTo(64));
    expect(size.width, lessThanOrEqualTo(360));
  });
}
