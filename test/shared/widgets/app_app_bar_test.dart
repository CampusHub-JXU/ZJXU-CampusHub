import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/shared/widgets/app_app_bar.dart';

import '../../helpers/test_setup.dart';

void main() {
  final activity = PageTransitionActivity.instance;

  setUp(() async {
    activity.debugReset();
    await resetTestEnvironment();
  });
  tearDown(activity.debugReset);

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

  // 颗粒噪点已移除：任何 CustomPaint 都不应出现在材质层里。
  Finder noisePainterFinder() => find.descendant(
    of: find.byType(BackdropFilter),
    matching: find.byType(CustomPaint),
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

  testWidgets('亚克力开启时渲染模糊层与标题', (tester) async {
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    final filterConfig = tester
        .widget<BackdropFilter>(find.byType(BackdropFilter))
        .filterConfig;
    expect(filterConfig, isA<ImageFilterConfig>());
  });

  testWidgets('亚克力关闭时回退实色且不创建 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('转场期间仅顶栏背景切实色，最后一次释放后恢复模糊', (tester) async {
    var taps = 0;
    await pumpBar(
      tester,
      bar: AppAppBar(
        title: const Text('标题'),
        actions: [
          IconButton(onPressed: () => taps++, icon: const Icon(Icons.add)),
        ],
      ),
    );
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    final action = find.byIcon(Icons.add);
    final actionRect = tester.getRect(action);
    final border = appBarFill(tester).border;
    expect(find.byType(BackdropFilter), findsOneWidget);

    activity.acquire();
    activity.acquire();
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(appBarFill(tester).color!.a, 1.0);
    expect(appBarFill(tester).border, border);
    expect(tester.widget<AppBar>(find.byType(AppBar)), same(appBar));
    expect(tester.getRect(action), actionRect);
    await tester.tap(action);
    expect(taps, 1);

    activity.release();
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);

    activity.release();
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('构建期间登记转场时，顶栏在下一帧安全切换材质', (tester) async {
    final beginTransition = ValueNotifier<bool>(false);
    addTearDown(beginTransition.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: const AppAppBar(title: Text('标题')),
          body: ValueListenableBuilder<bool>(
            valueListenable: beginTransition,
            builder: (context, begin, _) {
              if (begin) activity.acquire();
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    beginTransition.value = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);

    activity.release();
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('亚克力材质保留有界模糊、半透明填充，不再叠加颗粒', (tester) async {
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    final backdrop = find.byType(BackdropFilter);
    expect(backdrop, findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(backdrop).filterConfig.toString(),
      contains('bounded'),
    );
    expect(noisePainterFinder(), findsNothing);
    expect(appBarFill(tester).color!.a, lessThan(1.0));
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
