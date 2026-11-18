import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/system_surface/app_icon_switcher.dart';
import 'package:jxu_campus_hub/core/theme/app_icon_style.dart';
import 'package:jxu_campus_hub/core/theme/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_palette.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  test('resolveAppIconLauncherAlias 四款固定风格各自映射到固定 alias', () {
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.celadonSlate,
        seedColor: themePalettes[0].primary,
        presetPaletteIndex: 0,
      ),
      'LauncherCeladon',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.crimsonClassic,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
      ),
      'LauncherCrimson',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.themeInverted,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
      ),
      'LauncherRedBlack',
    );
    // 跟随主题色用 Auto 资源限定符款，运行时不再随主题模式翻转 alias
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.followTheme,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
      ),
      'LauncherTheme1Auto',
    );
    // 自定义种子映射到最近预设
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.followTheme,
        seedColor: const Color(0xFF2D7E31),
        presetPaletteIndex: null,
      ),
      'LauncherTheme6Auto',
    );
  });

  test('AppIconColors 跟随主题色深色款走色彩系统派生而非红黑反色', () {
    final seed = themePalettes[1].primary; // 嘉大蓝
    final dark = AppIconColors.resolve(
      style: AppIconStyle.followTheme,
      seed: seed,
      isDark: true,
    );
    // 帆 = 深色 scheme 的 tonal primary（tonalSpot T80），蓝主题不再变红帆
    expect(
      dark.sail,
      ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      ).primary,
    );
    // 底 = 种子调暗面，不再统一 #160609
    expect(dark.top, isNot(AppIconColors.redBlack));
    expect(dark.bottom, isNot(AppIconColors.redBlack));
    // 波纹沿用帆→底渐变带
    expect(dark.waves.first, dark.sail);
    expect(dark.waves.length, 3);

    final light = AppIconColors.resolve(
      style: AppIconStyle.followTheme,
      seed: seed,
      isDark: false,
    );
    expect(light.sail, seed);
  });

  test('AppIconColors 固定风格不随明暗变化', () {
    final seed = themePalettes[1].primary;
    // 「深色反色 · 红黑」是固定风格：深浅模式下都红黑底
    for (final isDark in [true, false]) {
      final colors = AppIconColors.resolve(
        style: AppIconStyle.themeInverted,
        seed: seed,
        isDark: isDark,
      );
      expect(colors.top, AppIconColors.redBlack, reason: 'isDark=$isDark');
    }
    // 青瓷浅色/黛瓦深色随资源限定符对应
    expect(
      AppIconColors.resolve(
        style: AppIconStyle.celadonSlate,
        seed: seed,
        isDark: false,
      ).top,
      AppIconColors.celadon.top,
    );
    expect(
      AppIconColors.resolve(
        style: AppIconStyle.celadonSlate,
        seed: seed,
        isDark: true,
      ).top,
      AppIconColors.slate.top,
    );
  });

  test('nearestIconPaletteIndex 为自定义色选出最近预设', () {
    expect(nearestIconPaletteIndex(const Color(0xFF1968C4)), 1);
    expect(nearestIconPaletteIndex(const Color(0xFF2D7E31)), 6);
  });

  test('AppPreferencesController 切换图标风格时同步桌面 alias', () async {
    final synced = <String>[];
    AppIconSwitcher.instance.debugOverrideSetAlias = (alias) async {
      synced.add(alias);
      return true;
    };

    final ctrl = AppPreferencesController.instance;
    await ctrl.setPaletteIndex(1); // 青瓷模式下换主题色不触发桌面切换
    expect(synced, ['LauncherCeladon']);

    await ctrl.setAppIconStyle(AppIconStyle.followTheme);
    expect(synced.last, 'LauncherTheme1Auto');

    // 主题模式变化不再触发 alias 翻转（深浅由资源限定符处理）
    await ctrl.setThemeMode(AppThemePreference.dark);
    expect(synced.last, 'LauncherTheme1Auto');

    await ctrl.setAppIconStyle(AppIconStyle.crimsonClassic);
    expect(synced.last, 'LauncherCrimson');

    // 重复设置相同风格不会重复触发通道调用
    final countBefore = synced.length;
    await ctrl.setAppIconStyle(AppIconStyle.crimsonClassic);
    expect(synced.length, countBefore);
  });
}
