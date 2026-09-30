import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/surface_material.dart';
import 'package:jxu_campus_hub/shared/widgets/app_app_bar.dart';
import 'package:jxu_campus_hub/shared/widgets/material_noise.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
    // 全局默认是云母（无模糊）；本文件覆盖玻璃配方的渲染分支。
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.glass,
    );
  });

  Future<void> pumpBar(WidgetTester tester, {PreferredSizeWidget? bar}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: bar ?? const AppAppBar(title: Text('标题')),
          body: const Center(child: Text('内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder noisePainterFinder() => find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is MaterialNoisePainter,
  );

  BoxDecoration appBarFill(WidgetTester tester) {
    final fill = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(GlassAppBarSpace),
        matching: find.byType(DecoratedBox),
      ),
    );
    return fill.decoration as BoxDecoration;
  }

  testWidgets('玻璃开启时渲染模糊层与标题', (tester) async {
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    final filterConfig = tester
        .widget<BackdropFilter>(find.byType(BackdropFilter))
        .filterConfig;
    expect(filterConfig, isA<ImageFilterConfig>());
  });

  testWidgets('玻璃关闭时回退实色且不创建 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('模糊强度拉到 0 时不创建 BackdropFilter（滑条 0 = 关模糊）', (tester) async {
    await GlassStyleController.instance.setBlurSigma(0);
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('亚克力材质保留有界模糊、半透明填充与细微噪点', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.acrylic,
    );
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    final backdrop = find.byType(BackdropFilter);
    expect(backdrop, findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(backdrop).filterConfig.toString(),
      contains('bounded'),
    );
    expect(noisePainterFinder(), findsOneWidget);
    expect(appBarFill(tester).color!.a, lessThan(1.0));
  });

  testWidgets('实色材质回退实色且不创建 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.solid,
    );
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('云母材质回退不透明主题色调表面且不创建 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setMaterialStyle(
      SurfaceMaterialStyle.mica,
    );
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(noisePainterFinder(), findsNothing);

    final color = appBarFill(tester).color!;
    expect(color.a, 1.0);

    // 主题色调：不透明顶栏填充必须与中性 surface 容器色可区分。
    final theme = Theme.of(tester.element(find.byType(GlassAppBarSpace)));
    final baseSurface = theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerLow
        : theme.colorScheme.surfaceContainerLowest;
    expect(color, isNot(equals(baseSurface)));
  });

  testWidgets('显式 backgroundColor 跳过玻璃层', (tester) async {
    await pumpBar(
      tester,
      bar: AppAppBar(title: const Text('扫码'), backgroundColor: Colors.black),
    );

    expect(find.text('扫码'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('preferredSize 计入 bottom 高度', (tester) async {
    final bar = AppAppBar(
      title: const Text('标题'),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(),
      ),
    );
    expect(bar.preferredSize.height, kToolbarHeight + 48);
  });

  testWidgets('默认顶栏按主题亮度指定状态栏图标颜色', (tester) async {
    await pumpBar(tester);
    expect(
      tester
          .widget<AppBar>(find.byType(AppBar))
          .systemOverlayStyle
          ?.statusBarIconBrightness,
      Brightness.dark,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          appBar: const AppAppBar(title: Text('标题')),
          body: const Center(child: Text('内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AppBar>(find.byType(AppBar))
          .systemOverlayStyle
          ?.statusBarIconBrightness,
      Brightness.light,
    );
  });

  testWidgets('显式 backgroundColor 时交由 AppBar 推导状态栏样式', (tester) async {
    await pumpBar(
      tester,
      bar: AppAppBar(title: const Text('扫码'), backgroundColor: Colors.black),
    );

    expect(
      tester.widget<AppBar>(find.byType(AppBar)).systemOverlayStyle,
      isNull,
    );
  });
}
