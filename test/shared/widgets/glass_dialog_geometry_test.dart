import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/app_feedback.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_dialog_route.dart';

import '../../helpers/test_setup.dart';

/// 共享玻璃确认弹窗的真实几何回归（Issue #46）。
///
/// 真机截图显示：短内容确认框（退出登录 / 清除离线缓存）的玻璃表面被内层
/// `AlertDialog` 自带的 `Dialog` + `Align` 撑到接近整屏。这里不看 `find.text`
/// 是否命中，而是直接量 [GlassOverlaySurface] 的**真实渲染边界**：
/// * 短内容必须 shrink-wrap —— 高度贴近实际内容，显著小于可用视口；
/// * 弹窗在屏幕内居中，宽度与 [showGlassDialog] 的 insetPadding 一致；
/// * 内容变长 / 字号放大时按需增高，超出可用高度则封顶并可滚动，按钮仍可触达。
void main() {
  setUp(() async {
    confirmResultSink.value = null;
    await resetTestEnvironment();
  });

  // ---- 现场搭建 -----------------------------------------------------------

  const shortMessage = '退出后，统一认证与教务都需要重新登录才能继续使用。';
  const longMessage =
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。'
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。'
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。'
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。'
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。'
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。'
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。'
      '这是一段用于验证超长内容的说明文字，会反复出现以填满弹窗并触发滚动。';

  /// 默认 insetPadding 的水平 / 垂直边距（`showGlassDialog` 缺省值）。
  const horizontalInset = 40.0;
  const verticalInset = 24.0;

  /// 弹一次确认框的真实入口：一个可点的宿主按钮 → `AppFeedback.confirm`。
  Future<void> openConfirm(
    WidgetTester tester, {
    required Size size,
    double textScale = 1.0,
    bool dark = false,
    double keyboardBottom = 0,
    bool disableAnimations = false,
    String message = shortMessage,
    bool? confirmResult,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardBottom);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? ThemeData.dark(useMaterial3: true) : null,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboardBottom),
            disableAnimations: disableAnimations,
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async {
                    final result = await AppFeedback.confirm(
                      context,
                      title: '退出登录',
                      message: message,
                      confirmLabel: '退出登录',
                      cancelLabel: '返回',
                      destructive: true,
                    );
                    confirmResultSink.value = result;
                  },
                  child: const Text('open-confirm'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-confirm'));
    await tester.pumpAndSettle();
  }

  Rect surfaceRect(WidgetTester tester) =>
      tester.getRect(find.byType(GlassOverlaySurface));

  Rect dialogRect(WidgetTester tester) =>
      tester.getRect(find.byType(AlertDialog));

  /// 玻璃表面不超出内容：表面高度应贴近内层 AlertDialog 的实际高度。
  void expectGlassHugsContent(WidgetTester tester) {
    final surface = surfaceRect(tester);
    final dialog = dialogRect(tester);
    expect(
      (surface.height - dialog.height).abs(),
      lessThanOrEqualTo(4),
      reason: '玻璃表面高度应贴合内容（表面 ${surface.height} vs 内容 ${dialog.height}）',
    );
  }

  // ---- 短内容：随尺寸 / 字号 / 主题自适应收缩 ------------------------------

  for (final size in const <Size>[
    Size(360, 640),
    Size(390, 844),
    Size(800, 1280),
  ]) {
    testWidgets('短确认框在 $size 关闭动画时 shrink-wrap 并居中', (tester) async {
      await openConfirm(tester, size: size, disableAnimations: true);

      final surface = surfaceRect(tester);
      final availableHeight = size.height - 2 * verticalInset;

      expect(tester.takeException(), isNull);
      expectGlassHugsContent(tester);
      expect(
        surface.height,
        lessThan(availableHeight - 40),
        reason: '短内容不该接近可用高度（表面 ${surface.height}, 可用 $availableHeight）',
      );
      expect(
        surface.height / size.height,
        lessThan(0.5),
        reason: '手机标准字号下应明显小于半屏',
      );
      // 居中：表面中心与屏幕中心一致。
      expect(
        (surface.center.dy - size.height / 2).abs(),
        lessThanOrEqualTo(1.5),
      );
      // 宽度 = 屏宽 - 2×水平边距。
      expect(surface.width, closeTo(size.width - 2 * horizontalInset, 0.5));
    });
  }

  for (final scale in const <double>[1.0, 1.5, 2.0]) {
    testWidgets('短确认框在 390x844 textScaler=$scale 不撑满、不溢出', (tester) async {
      await openConfirm(tester, size: const Size(390, 844), textScale: scale);

      final surface = surfaceRect(tester);
      expect(tester.takeException(), isNull);
      expectGlassHugsContent(tester);
      expect(
        surface.height / 844,
        lessThan(0.5),
        reason: 'textScaler=$scale 时仍应 shrink-wrap',
      );
    });
  }

  testWidgets('短确认框在横屏 844x390 不撑满、不溢出', (tester) async {
    await openConfirm(
      tester,
      size: const Size(844, 390),
      disableAnimations: true,
    );

    final surface = surfaceRect(tester);
    expect(tester.takeException(), isNull);
    expectGlassHugsContent(tester);
    // 横屏视口矮，内容本身占比较大；关键是封顶而非整屏。
    expect(surface.height, lessThan(390 - 2 * verticalInset));
    expect(surface.height / 390, lessThan(0.6));
  });

  testWidgets('深色模式短确认框同样 shrink-wrap', (tester) async {
    await openConfirm(tester, size: const Size(390, 844), dark: true);
    expect(tester.takeException(), isNull);
    expectGlassHugsContent(tester);
    expect(surfaceRect(tester).height / 844, lessThan(0.5));
  });

  testWidgets('玻璃关闭（实色降级）时同样 shrink-wrap 且无 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await openConfirm(tester, size: const Size(390, 844));

    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    expectGlassHugsContent(tester);
    expect(surfaceRect(tester).height / 844, lessThan(0.5));
  });

  // ---- 键盘弹出：在收缩后的可用区域内居中、不溢出 -------------------------

  testWidgets('键盘弹出时确认框在剩余区域内居中且不溢出', (tester) async {
    await openConfirm(
      tester,
      size: const Size(390, 844),
      keyboardBottom: 300,
      disableAnimations: true,
    );

    final surface = surfaceRect(tester);
    expect(tester.takeException(), isNull);
    expectGlassHugsContent(tester);
    // 可用区域 = 屏高 - 键盘；中心应落在其中点。
    expect(
      (surface.center.dy - (844 - 300) / 2).abs(),
      lessThanOrEqualTo(2),
      reason: '应居中于键盘上方的可用区域',
    );
    expect(surface.bottom, lessThanOrEqualTo(844 - 300));
  });

  // ---- 长内容：内容驱动增高，封顶后可滚动、按钮可触达 ---------------------

  testWidgets('短内容高度 < 长内容高度（高度由内容驱动，非固定值）', (tester) async {
    await openConfirm(tester, size: const Size(390, 844));
    final shortHeight = surfaceRect(tester).height;
    // 关闭后重新打开长内容，避免复用同一个弹窗。
    await tester.tap(find.widgetWithText(TextButton, '返回'));
    await tester.pumpAndSettle();

    await openConfirm(tester, size: const Size(390, 844), message: longMessage);
    final longHeight = surfaceRect(tester).height;

    expect(shortHeight, lessThan(longHeight));
  });

  testWidgets('超长内容在 360x640 2x 字号下封顶可滚动，确认按钮可达', (tester) async {
    await openConfirm(
      tester,
      size: const Size(360, 640),
      textScale: 2.0,
      message: longMessage,
    );

    final surface = surfaceRect(tester);
    expect(tester.takeException(), isNull);
    // 封顶到可用高度（屏高 - 2×垂直边距），不会溢出屏幕。
    expect(surface.height, lessThanOrEqualTo(640 - 2 * verticalInset + 0.5));
    expect(surface.top, greaterThanOrEqualTo(verticalInset - 0.5));

    // 按钮仍在树中，滚动后可达并被点击。
    final confirm = find.widgetWithText(TextButton, '退出登录');
    expect(confirm, findsOneWidget);
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(confirmResultSink.value, isTrue);
  });

  // ---- 其它调用方审计：内容含滚动视图时不崩、且仍 shrink-wrap -------------

  testWidgets('内容含 SingleChildScrollView（更新弹窗形态）时 shrink-wrap 且不溢出', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showGlassDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  title: const Text('发现新版本'),
                  content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('发布时间：2026-10-10'),
                          const SizedBox(height: 12),
                          for (var i = 0; i < 6; i++) Text('更新项 $i'),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('稍后再说')),
                  ],
                ),
              ),
              child: const Text('open-update'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-update'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expectGlassHugsContent(tester);
    final surface = surfaceRect(tester);
    expect(surface.height, lessThan(800 - 2 * verticalInset));
  });

  testWidgets('内容含 ListView(shrinkWrap)（日历选择形态）时不崩且 shrink-wrap', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showGlassDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  title: const Text('选择目标日历'),
                  content: SizedBox(
                    width: double.maxFinite,
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (var i = 0; i < 3; i++)
                          ListTile(title: Text('日历 $i')),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('取消')),
                  ],
                ),
              ),
              child: const Text('open-calendar'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-calendar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expectGlassHugsContent(tester);
    expect(surfaceRect(tester).height, lessThan(800 - 2 * verticalInset));
  });
}

/// 最近一次确认框的返回值（供「长内容按钮可达」用例断言）。
final ValueNotifier<bool?> confirmResultSink = ValueNotifier<bool?>(null);
