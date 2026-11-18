import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/features/settings/personalization_page.dart';
import 'package:jxu_campus_hub/core/theme/app_icon_style.dart';
import 'package:jxu_campus_hub/core/theme/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/storage/app_preferences_store.dart';

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

  Finder mainScrollable() => find
      .descendant(
        of: find.byKey(const Key('personalization_scroll')),
        matching: find.byType(Scrollable),
      )
      .first;

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 300, scrollable: mainScrollable());
    await tester.ensureVisible(finder);
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await scrollTo(tester, finder);
    await tester.tap(finder);
    await tester.pump();
  }

  testWidgets('各分组按设计顺序出现', (tester) async {
    await pumpPersonalization(tester);

    expect(find.text('主题模式'), findsOneWidget);
    await scrollTo(tester, find.text('壁纸'));
    expect(find.text('壁纸'), findsOneWidget);
    expect(find.text('更换壁纸'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);
    await scrollTo(tester, find.text('效果'));
    expect(find.text('效果'), findsOneWidget);
    expect(find.text('耗电'), findsOneWidget);
    await scrollTo(tester, find.text('首页内容'));
    expect(find.text('首页内容'), findsOneWidget);
  });

  testWidgets('开关写回对应控制器', (tester) async {
    // Shader 默认开启会展开四条滑条把下方开关挤出首屏；这里只测下方开关。
    personalization.shaderEnabled.value = false;
    await pumpPersonalization(tester);

    // 亚克力始终开启：设置页不再提供材质 / 课表卡片毛玻璃开关。
    expect(glass.enabled.value, isTrue);
    expect(find.byKey(const Key('personalization_acrylic')), findsNothing);
    expect(find.byKey(const Key('personalization_header_glass')), findsNothing);

    // 磨砂闪粉：用户开关已下线，材质总控恒为关闭。
    expect(glass.frostGrainEnabled.value, isFalse);
    expect(find.byKey(const Key('personalization_frost_grain')), findsNothing);

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

  testWidgets('Shader 默认开启：展开帧率 / 速度 / 强度 / 不透明度四条滑条', (tester) async {
    // 出厂默认：开。
    expect(personalization.shaderEnabled.value, isTrue);
    await pumpPersonalization(tester);
    for (final key in const [
      'personalization_shader_fps',
      'personalization_shader_speed',
      'personalization_shader_strength',
      'personalization_shader_opacity',
    ]) {
      await scrollTo(tester, find.byKey(Key(key)));
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    await scrollTo(tester, find.text('60 fps'));
    expect(find.text('60 fps'), findsOneWidget);
  });

  testWidgets('帧率滑条：档位写回控制器并持久化，关闭 Shader 后消失', (tester) async {
    await pumpPersonalization(tester);
    final slider = find.byKey(const Key('personalization_shader_fps'));
    await scrollTo(tester, slider);
    expect(slider, findsOneWidget);
    expect(personalization.shaderFps.value, 60);

    // 档位 30 / 45 / 60 / 90 / 120 对应 0..4；拖到最左 = 30，最右 = 120。
    await tester.drag(slider, const Offset(-600, 0));
    await tester.pump();
    expect(personalization.shaderFps.value, 30);
    expect(find.text('30 fps'), findsOneWidget);

    await tester.drag(slider, const Offset(600, 0));
    await tester.pump();
    expect(personalization.shaderFps.value, 120);

    await tapKey(tester, 'personalization_shader');
    expect(personalization.shaderEnabled.value, isFalse);
    expect(find.byKey(const Key('personalization_shader_fps')), findsNothing);
  });

  testWidgets('Shader 关闭时不显示参数滑条，开启后展开', (tester) async {
    personalization.shaderEnabled.value = false;
    await pumpPersonalization(tester);

    const sliders = [
      'personalization_shader_fps',
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
      await scrollTo(tester, find.byKey(Key(key)));
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    await scrollTo(tester, find.text('1.0×'));
    expect(find.text('1.0×'), findsOneWidget);
    await scrollTo(tester, find.text('45%'));
    expect(find.text('45%'), findsOneWidget);
  });

  testWidgets('无壁纸时不显示「移除壁纸」，有壁纸时移除并关闭 Shader', (tester) async {
    await pumpPersonalization(tester);
    expect(
      find.byKey(const Key('personalization_remove_wallpaper')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('personalization_edit_transform')),
      findsNothing,
    );

    await personalization.setBackgroundImagePath('/nonexistent/bg.jpg');
    await personalization.setShaderEnabled(true);
    await tester.pump();
    await scrollTo(tester, find.text('自定义'));
    expect(find.text('自定义'), findsOneWidget);
    await scrollTo(
      tester,
      find.byKey(const Key('personalization_edit_transform')),
    );
    expect(
      find.byKey(const Key('personalization_edit_transform')),
      findsOneWidget,
    );

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

    final segmentsFinder = find.byKey(
      const Key('personalization_fit_segments'),
    );
    await scrollTo(tester, segmentsFinder);
    SegmentedButton<HomeBackgroundFit> segments() =>
        tester.widget<SegmentedButton<HomeBackgroundFit>>(segmentsFinder);

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
    await scrollTo(tester, find.text('35%'));
    expect(find.text('35%'), findsOneWidget);
  });

  testWidgets('应用图标选择立即更新并持久化，无深浅翻转开关', (tester) async {
    await pumpPersonalization(tester);
    await scrollTo(tester, find.text('应用图标'));
    expect(find.text('应用图标'), findsOneWidget);
    // 自动深色/跟随开关已移除：用户直接选固定风格
    expect(
      find.byKey(const Key('personalization_icon_dark_invert')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('personalization_icon_follow_theme')),
      findsNothing,
    );
    await tapKey(tester, 'personalization_icon_crimsonClassic');
    expect(
      AppPreferencesController.instance.state.appIconStyle,
      AppIconStyle.crimsonClassic,
    );
    await tapKey(tester, 'personalization_icon_followTheme');
    expect(
      AppPreferencesController.instance.state.appIconStyle,
      AppIconStyle.followTheme,
    );
    await tester.pumpAndSettle();
    final saved = await AppPreferencesStore.instance.load();
    expect(saved.appIconStyle, AppIconStyle.followTheme);
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
        'personalization_edit_transform',
        'personalization_reset_transform',
        'personalization_remove_wallpaper',
        'personalization_shader_opacity',
        'personalization_campus_notice',
      ]) {
        await scrollTo(tester, find.byKey(Key(key)));
        expect(tester.takeException(), isNull, reason: key);
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
