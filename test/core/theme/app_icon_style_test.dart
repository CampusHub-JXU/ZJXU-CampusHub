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

  test('resolveAppIconLauncherAlias 三款风格各自映射到支持深浅自动切换的 alias', () {
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.monochromeAuto,
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

  test('AppIconColors 三款风格均随系统明暗模式自动互换', () {
    final seed = themePalettes[1].primary;
    // 默认「黑白 · 互换」：浅色白底黑帆，深色黑底白帆
    final monoLight = AppIconColors.resolve(
      style: AppIconStyle.monochromeAuto,
      seed: seed,
      isDark: false,
    );
    final monoDark = AppIconColors.resolve(
      style: AppIconStyle.monochromeAuto,
      seed: seed,
      isDark: true,
    );
    expect(monoLight.top, Colors.white);
    expect(monoLight.sail, AppIconColors.inkBlack);
    expect(monoDark.top, AppIconColors.inkBlack);
    expect(monoDark.sail, AppIconColors.ivory);

    // 「嘉大红」：浅色嘉大红底白帆，深色红黑底亮红帆
    final crimsonLight = AppIconColors.resolve(
      style: AppIconStyle.crimsonClassic,
      seed: seed,
      isDark: false,
    );
    final crimsonDark = AppIconColors.resolve(
      style: AppIconStyle.crimsonClassic,
      seed: seed,
      isDark: true,
    );
    expect(crimsonLight.sail, AppIconColors.ivory);
    expect(crimsonDark.top, AppIconColors.redBlack);
    expect(crimsonDark.sail, AppIconColors.crimsonBright);
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
