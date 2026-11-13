import 'package:flutter/material.dart';
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

  test('resolveAppIconLauncherAlias 覆盖青瓷/红黑/嘉大红/跟随主题色各组合', () {
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.celadonSlate,
        seedColor: themePalettes[0].primary,
        presetPaletteIndex: 0,
        followThemeColor: false,
        darkInvert: true,
        themeModeName: 'system',
      ),
      'LauncherCeladon',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.celadonSlate,
        seedColor: themePalettes[0].primary,
        presetPaletteIndex: 0,
        followThemeColor: false,
        darkInvert: false,
        themeModeName: 'system',
      ),
      'LauncherCeladonDay',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.crimsonClassic,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
        followThemeColor: false,
        darkInvert: true,
        themeModeName: 'system',
      ),
      'LauncherCrimson',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.themeInverted,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
        followThemeColor: false,
        darkInvert: true,
        themeModeName: 'light',
      ),
      'LauncherRedBlack',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.followTheme,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
        followThemeColor: true,
        darkInvert: true,
        themeModeName: 'system',
      ),
      'LauncherTheme1Auto',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.followTheme,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
        followThemeColor: true,
        darkInvert: true,
        themeModeName: 'light',
      ),
      'LauncherTheme1',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.followTheme,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
        followThemeColor: true,
        darkInvert: true,
        themeModeName: 'dark',
      ),
      'LauncherTheme1Dark',
    );
    expect(
      resolveAppIconLauncherAlias(
        style: AppIconStyle.followTheme,
        seedColor: themePalettes[1].primary,
        presetPaletteIndex: 1,
        followThemeColor: true,
        darkInvert: false,
        themeModeName: 'dark',
      ),
      'LauncherTheme1',
    );
  });

  test('nearestIconPaletteIndex 为自定义色选出最近预设', () {
    expect(nearestIconPaletteIndex(const Color(0xFF1968C4)), 1);
    expect(nearestIconPaletteIndex(const Color(0xFF2D7E31)), 6);
  });

  test('AppPreferencesController 切换图标与主题色时去重同步桌面 alias', () async {
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

    await ctrl.setThemeMode(AppThemePreference.dark);
    expect(synced.last, 'LauncherTheme1Dark');

    await ctrl.setIconDarkInvert(false);
    expect(synced.last, 'LauncherTheme1');

    // 重复设置相同模式不会重复触发通道调用
    final countBefore = synced.length;
    await ctrl.setIconDarkInvert(false);
    expect(synced.length, countBefore);
  });
}
