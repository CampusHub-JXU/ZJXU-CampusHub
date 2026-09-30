import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/features/settings/personalization_page.dart';
import 'package:jxu_campus_hub/features/settings/widgets/appearance_preview.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final personalization = PersonalizationController.instance;
  final glass = GlassStyleController.instance;

  setUp(() async {
    await resetTestEnvironment();
  });

  Future<void> pumpPersonalization(
    WidgetTester tester, {
    Size size = const Size(412, 900),
    double textScale = 1.0,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: PersonalizationPage(
          homeSceneBuilder: (context) => const Center(child: Text('真实首页场景')),
        ),
      ),
    );
    await tester.pump();
  }

  ScrollPosition scrollPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('personalization_scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  testWidgets('三个分组按设计顺序出现', (tester) async {
    await pumpPersonalization(tester);

    expect(find.text('壁纸'), findsOneWidget);
    expect(find.text('更换壁纸'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);
    scrollPosition(tester).jumpTo(scrollPosition(tester).maxScrollExtent);
    await tester.pump();
    expect(find.text('效果'), findsOneWidget);
    expect(find.text('耗电'), findsOneWidget);
    expect(find.text('首页内容'), findsOneWidget);
  });

  testWidgets('开关写回对应控制器', (tester) async {
    await pumpPersonalization(tester);

    expect(glass.enabled.value, isTrue);
    await tapKey(tester, 'personalization_acrylic');
    expect(glass.enabled.value, isFalse);

    expect(personalization.headerGlassEnabled.value, isFalse);
    await tapKey(tester, 'personalization_header_glass');
    expect(personalization.headerGlassEnabled.value, isTrue);

    expect(personalization.emblemWatermarkEnabled.value, isTrue);
    await tapKey(tester, 'personalization_emblem');
    expect(personalization.emblemWatermarkEnabled.value, isFalse);

    expect(personalization.fullDayCoursesEnabled.value, isTrue);
    await tapKey(tester, 'personalization_full_day');
    expect(personalization.fullDayCoursesEnabled.value, isFalse);

    expect(personalization.homeCampusNoticeEnabled.value, isFalse);
    await tapKey(tester, 'personalization_campus_notice');
    expect(personalization.homeCampusNoticeEnabled.value, isTrue);
  });

  testWidgets('Shader 关闭时不显示三条参数滑条，开启后展开', (tester) async {
    await pumpPersonalization(tester);

    const sliders = [
      'personalization_shader_speed',
      'personalization_shader_strength',
      'personalization_shader_opacity',
    ];
    for (final key in sliders) {
      expect(find.byKey(Key(key)), findsNothing);
    }

    await tapKey(tester, 'personalization_shader');
    expect(personalization.shaderEnabled.value, isTrue);
    for (final key in sliders) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    expect(find.text('1.0×'), findsOneWidget);
    expect(find.text('45%'), findsOneWidget);
  });

  testWidgets('无壁纸时不显示「移除壁纸」，有壁纸时移除并关闭 Shader', (tester) async {
    await pumpPersonalization(tester);
    expect(
      find.byKey(const Key('personalization_remove_wallpaper')),
      findsNothing,
    );

    await personalization.setBackgroundImagePath('/nonexistent/bg.jpg');
    await personalization.setShaderEnabled(true);
    await tester.pump();
    expect(find.text('自定义'), findsOneWidget);

    await tapKey(tester, 'personalization_remove_wallpaper');
    expect(personalization.backgroundImagePath.value, isNull);
    expect(personalization.shaderEnabled.value, isFalse);
    expect(
      find.byKey(const Key('personalization_remove_wallpaper')),
      findsNothing,
    );
  });

  testWidgets('填充分段映射到 backgroundFit，旧档位显示为未选中', (tester) async {
    await pumpPersonalization(tester);

    SegmentedButton<HomeBackgroundFit> segments() =>
        tester.widget<SegmentedButton<HomeBackgroundFit>>(
          find.byKey(const Key('personalization_fit_segments')),
        );

    expect(segments().selected, {HomeBackgroundFit.cover});

    await tester.tap(find.text('适应'));
    await tester.pump();
    expect(personalization.backgroundFit.value, HomeBackgroundFit.contain);

    await tester.tap(find.text('居中').first);
    await tester.pump();
    expect(personalization.backgroundFit.value, HomeBackgroundFit.none);

    // 再点已选中档不会清空。
    await tester.tap(find.text('居中').first);
    await tester.pump();
    expect(personalization.backgroundFit.value, HomeBackgroundFit.none);

    await personalization.setBackgroundFit(HomeBackgroundFit.fitWidth);
    await tester.pump();
    expect(segments().selected, isEmpty);

    await tester.tap(find.text('铺满'));
    await tester.pump();
    expect(personalization.backgroundFit.value, HomeBackgroundFit.cover);
  });

  testWidgets('壁纸不透明度显示百分比', (tester) async {
    await pumpPersonalization(tester);
    await personalization.setBackgroundOpacity(0.35);
    await tester.pump();
    expect(find.text('35%'), findsOneWidget);
  });

  testWidgets('预览随滚动从 300 收缩到 120 并固定', (tester) async {
    await pumpPersonalization(tester, size: const Size(412, 700));
    final preview = find.byKey(const Key('personalization_preview'));
    expect(tester.getSize(preview).height, 300);

    scrollPosition(tester).jumpTo(90);
    await tester.pump();
    expect(tester.getSize(preview).height, closeTo(210, 0.5));

    await tester.drag(
      find.byKey(const Key('personalization_scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(scrollPosition(tester).pixels, greaterThan(180));
    expect(tester.getSize(preview).height, 120);
    expect(preview, findsOneWidget);
  });

  testWidgets('场景切换：主页用真实首页场景，功能/我的为静态示意', (tester) async {
    await pumpPersonalization(tester);
    expect(find.text('真实首页场景'), findsOneWidget);

    await tester.tap(find.text('功能'));
    await tester.pump();
    expect(find.text('真实首页场景'), findsNothing);
    expect(
      tester.widget<AppearancePreview>(find.byType(AppearancePreview)).scene,
      AppearancePreviewScene.functions,
    );

    await tester.tap(find.text('我的'));
    await tester.pump();
    expect(
      tester.widget<AppearancePreview>(find.byType(AppearancePreview)).scene,
      AppearancePreviewScene.my,
    );

    await tester.tap(find.text('主页'));
    await tester.pump();
    expect(find.text('真实首页场景'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('360 宽 1.3× 字号展开全部项无溢出（${brightness.name}）', (tester) async {
      await personalization.setBackgroundImagePath('/nonexistent/bg.jpg');
      await personalization.setShaderEnabled(true);
      await personalization.setBackgroundAlignment(const Alignment(0.4, 0));
      await pumpPersonalization(
        tester,
        size: const Size(360, 720),
        textScale: 1.3,
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);

      for (final key in [
        'personalization_fit_segments',
        'personalization_reset_transform',
        'personalization_remove_wallpaper',
        'personalization_shader_opacity',
        'personalization_header_glass',
        'personalization_campus_notice',
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: key);
      }

      for (final scene in ['功能', '我的']) {
        await tester.tap(find.text(scene));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: scene);
      }
    });
  }

  testWidgets('复原位置与缩放只在移动过壁纸后出现', (tester) async {
    await personalization.setBackgroundImagePath('/nonexistent/bg.jpg');
    await pumpPersonalization(tester);
    expect(
      find.byKey(const Key('personalization_reset_transform')),
      findsNothing,
    );

    await personalization.setBackgroundScale(1.4);
    await tester.pump();
    await tapKey(tester, 'personalization_reset_transform');
    await tester.pump();
    expect(personalization.backgroundScale.value, 1.0);
    expect(personalization.backgroundAlignment.value, Alignment.center);
    expect(
      find.byKey(const Key('personalization_reset_transform')),
      findsNothing,
    );
  });
}
