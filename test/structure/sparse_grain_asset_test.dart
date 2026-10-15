import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/shared/widgets/frost_grain.dart';

/// Issue #47 结构守卫：稀疏闪粉必须是**离线预生成 + 平铺贴图**，不得退回
/// 「运行时逐像素生成 64×64 高噪点」的旧实现，也不得让生成器引入 CI 依赖。
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final grainSource = File('lib/shared/widgets/frost_grain.dart')
      .readAsStringSync();
  final generator = File('tools/materials/generate_frost_grain.py');

  test('pubspec 注册了贴图资源目录', () {
    expect(
      pubspec.contains('assets/textures/'),
      isTrue,
      reason: '缺少 assets/textures/ 注册时 AssetImage 在真机上加载不到贴图',
    );
    expect(File(kFrostGrainAsset).existsSync(), isTrue);
  });

  test('frost_grain.dart 不再在运行时生成 / 编码像素', () {
    // 旧实现：进程内 ZLib 编码 64×64 逐像素噪声 PNG + MemoryImage。
    expect(
      grainSource.contains('ZLibCodec'),
      isFalse,
      reason: '不得恢复运行时 PNG 编码',
    );
    expect(
      grainSource.contains('_buildNoisePng'),
      isFalse,
      reason: '不得恢复逐像素噪声生成',
    );
    expect(
      grainSource.contains('MemoryImage'),
      isFalse,
      reason: '不得恢复内存生成的噪点图',
    );
    expect(
      grainSource.contains('dart:typed_data'),
      isFalse,
      reason: '不应再手写像素缓冲',
    );
    // 新实现：预生成资源 + DecorationImage 平铺。
    expect(grainSource.contains('AssetImage'), isTrue);
    expect(grainSource.contains('DecorationImage'), isTrue);
    expect(grainSource.contains('ImageRepeat.repeat'), isTrue);
  });

  test('三个材质调用点仍使用 frostGrainImage', () {
    for (final path in const [
      'lib/shared/widgets/app_tile_surface.dart',
      'lib/shared/widgets/app_app_bar.dart',
      'lib/shared/widgets/glass_container.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source.contains("import 'frost_grain.dart';"),
        isTrue,
        reason: '$path 应继续依赖 frost_grain.dart',
      );
      expect(
        source.contains('frostGrainImage('),
        isTrue,
        reason: '$path 应继续通过 frostGrainImage 取颗粒',
      );
    }
  });

  test('生成器存在、纯标准库、输出路径与 Dart 常量一致', () {
    expect(generator.existsSync(), isTrue);
    final source = generator.readAsStringSync();
    for (final banned in const [
      'import numpy',
      'from PIL',
      'import PIL',
      'import scipy',
    ]) {
      expect(
        source.contains(banned),
        isFalse,
        reason: '生成器不得依赖 $banned（CI 未固定该依赖）',
      );
    }
    // 默认输出必须就是被 pubspec 注册、被 Dart 引用的那个文件。
    expect(source.contains('frost_grain_peaks.png'), isTrue);
    expect(kFrostGrainAsset, 'assets/textures/frost_grain_peaks.png');
  });
}
