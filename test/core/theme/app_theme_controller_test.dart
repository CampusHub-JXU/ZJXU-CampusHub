import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/app/theme.dart';

void main() {
  setUp(AppThemeController.instance.debugReset);

  testWidgets('普通图标颜色应使用主题色而非入口强调色', (tester) async {
    const accent = Color(0xFF7B61FF);
    const seed = Color(0xFF00695C);
    Color? resolved;
    Color? themePrimary;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
        home: Builder(
          builder: (context) {
            themePrimary = Theme.of(context).colorScheme.primary;
            resolved = AppThemeController.instance.resolveIconColor(
              context,
              accent,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(resolved, themePrimary);
    expect(resolved, isNot(accent));
  });

  testWidgets('语义图标颜色应保留调用方传入色', (tester) async {
    const semantic = Color(0xFFB3261E);
    const seed = Color(0xFF00695C);
    Color? resolved;
    Color? themePrimary;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
        home: Builder(
          builder: (context) {
            themePrimary = Theme.of(context).colorScheme.primary;
            resolved = AppThemeController.instance.resolveIconColor(
              context,
              semantic,
              semantic: true,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(resolved, semantic);
    expect(resolved, isNot(themePrimary));
  });

  test('首页文字颜色通知器应反映统一偏好控制器同步值', () {
    AppThemeController.instance.updateHomeTextColorMode(HomeTextColorMode.dark);
    expect(
      AppThemeController.instance.homeTextColorMode.value,
      HomeTextColorMode.dark,
    );
  });

  test('预设颜色和标签应保留既有公开值', () {
    expect(AppThemeController.presetSeedColors.length, 8);
    expect(AppThemeController.presetSeedLabels.first, '嘉大红');
    expect(AppThemeController.presetSeedLabels.last, '石墨');
  });

  test('石墨暗色主题应保持中性灰阶', () {
    final theme = AppTheme.darkThemeFor(AppThemeController.presetSeedColors[7]);

    expect(theme.colorScheme.primary, const Color(0xFF455A64));
    expect(theme.colorScheme.surface, const Color(0xFF171C20));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF101418));
  });
}
