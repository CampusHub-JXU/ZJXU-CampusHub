import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/app_theme_controller.dart';
import 'package:jxu_campus_hub/app/theme.dart';

void main() {
  setUp(AppThemeController.instance.debugReset);

  testWidgets('图标颜色应透传入口强调色', (tester) async {
    const accent = Color(0xFF7B61FF);
    Color? resolved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            resolved = AppThemeController.instance.resolveIconColor(
              context,
              accent,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(resolved, accent);
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
