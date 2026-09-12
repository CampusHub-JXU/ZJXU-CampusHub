import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/theme/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/features/settings/appearance_page.dart';

import '../../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    AppPreferencesController.instance.debugReset();
    AppThemeController.instance.debugReset();
  });

  testWidgets('外观页展示主题与设置区块', (tester) async {
    await pumpPage(tester, const AppearancePage());

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
  });

  testWidgets('注入的首页场景构建器用于预览', (tester) async {
    await pumpPage(
      tester,
      AppearancePage(
        homeSceneBuilder: (context) => const Center(child: Text('真实首页场景')),
      ),
    );

    expect(find.text('真实首页场景'), findsOneWidget);
  });

  testWidgets('自定义主题色弹层保存后应切换到 custom 色源', (tester) async {
    await pumpPage(tester, const AppearancePage());

    await tester.ensureVisible(
      find.byKey(const ValueKey('custom-theme-color-button')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('custom-theme-color-button')));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);

    final colorPlane = find.byKey(const ValueKey('hsv-color-plane'));
    await tester.tapAt(tester.getTopLeft(colorPlane) + const Offset(220, 24));
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final state = AppPreferencesController.instance.state;
    expect(state.colorSource, AppColorPreference.custom);
    expect(
      state.customSeedColor,
      isNot(AppThemeController.defaultCustomSeedColor),
    );
    expect(state.seedColor, state.customSeedColor);
  });
}
