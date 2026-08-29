import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';

/// 预览渲染使用的种子色（嘉大红，与 App 默认主题一致）。
const Color kPreviewSeed = Color(0xFF8B1A2D);

/// 预览渲染的逻辑尺寸 / DPR（接近主流 Android 真机竖屏）。
const Size kPreviewLogicalSize = Size(412, 904);
const double kPreviewDpr = 3.0;

/// 黄金文件输出目录（相对 test/preview/，即仓库根 preview/render/）。
const String kGoldenDir = '../../preview/render';

bool _prepared = false;

/// 预览环境准备：加载本机中文字体 + 屏蔽真实网络。
///
/// 只在 `JXU_PREVIEW_RENDER=1`（tools/render_previews.ps1）下运行，
/// 普通 `flutter test` 中这些场景整体 skip，不产生任何副作用。
Future<void> setUpPreviewEnvironment() async {
  if (_prepared) return;
  _prepared = true;
  await _loadLocalFontAsInter();
  HttpOverrides.global = _BlockedNetworkHttpOverrides();
}

/// flutter_test 默认只有 Ahem 方块字体。预览需要三类字形：
/// 1. MaterialIcons（Flutter SDK 缓存自带，图标不加载就是豆腐块）；
/// 2. 中文字体注册到 'Inter'（App 全局 fontFamily）、'Roboto' 与 'Ahem'
///    （无 fontFamily 的显式 TextStyle 在测试环境的回退家族）；
/// 3. .ttc 容器格式若 FontLoader 不支持则逐个候选降级。
Future<void> _loadLocalFontAsInter() async {
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ?? r'F:\Coding\vibecoding\flutter';
  final iconFont = File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (iconFont.existsSync()) {
    try {
      final data = await iconFont.readAsBytes();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(Uint8List.fromList(data).buffer)));
      await loader.load();
    } catch (_) {
      // 图标加载失败只影响观感，不阻塞预览。
    }
  }

  const candidates = [
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\simhei.ttf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final data = await file.readAsBytes();
      for (final family in const ['Inter', 'Roboto', 'Ahem']) {
        final bytes = ByteData.view(Uint8List.fromList(data).buffer);
        final loader = FontLoader(family)..addFont(Future.value(bytes));
        await loader.load();
      }
      return;
    } catch (_) {
      // 继续尝试下一个候选字体。
    }
  }
}

/// 预览渲染屏蔽外发网络：所有 HttpClient 走 127.0.0.1:9（立即拒绝连接），
/// 让页面内的异步刷新离线快速失败，渲染出真实的空态/错误态/未登录态。
class _BlockedNetworkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..connectionTimeout = const Duration(milliseconds: 200)
      // findProxy 必须放在级联末尾：`=> 'xxx'..` 会被解析为对字符串字面量级联。
      ..findProxy = (uri) => 'PROXY 127.0.0.1:9';
  }
}

/// 以固定尺寸与主题泵入一个预览场景。
///
/// 只做有界泵（不在加载转圈上 pumpAndSettle 挂起），让首帧动画落定。
/// 环境准备（字体/网络屏蔽）必须在 main 的 setUpAll 里调用
/// [setUpPreviewEnvironment]——FontLoader 依赖真实事件循环，
/// 在 testWidgets 的 FakeAsync 区内 await 会永久挂起。
/// 预览主题垫片：theme 里显式 TextStyle（appBar 标题、chip、snackbar、按钮
/// label）没有 fontFamily，测试环境回退到不可读的方块字体；统一补上 'Inter'。
/// 真机上这些字段回退系统字体，无此问题。
ThemeData previewTheme(ThemeData theme) {
  const family = TextStyle(fontFamily: 'Inter');
  TextStyle? patchStyle(TextStyle? style) => style?.merge(family) ?? family;
  // 按钮主题的 textStyle 必须整粒 copyWith 替换（merge 在 WidgetStateProperty
  // 上不生效），并补全 size/weight，避免无 fontFamily/无 fontSize 的残缺样式
  // 在测试环境回退成方块字形。
  const buttonLabelTextStyle = TextStyle(
    fontFamily: 'Inter',
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
  ButtonStyle patchButtonStyle(ButtonStyle? style, {ButtonStyle? fallback}) =>
      (style ?? fallback ?? const ButtonStyle()).copyWith(
        textStyle: const WidgetStatePropertyAll(buttonLabelTextStyle),
      );
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: patchStyle(theme.appBarTheme.titleTextStyle),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: patchStyle(theme.chipTheme.labelStyle),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: patchStyle(theme.snackBarTheme.contentTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: patchButtonStyle(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patchButtonStyle(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: patchButtonStyle(theme.textButtonTheme.style),
    ),
  );
}

Future<void> pumpPreviewScene(
  WidgetTester tester,
  WidgetBuilder builder, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = kPreviewDpr;
  tester.view.physicalSize = Size(
    kPreviewLogicalSize.width * kPreviewDpr,
    kPreviewLogicalSize.height * kPreviewDpr,
  );
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: previewTheme(AppThemeBuilder.light(kPreviewSeed)),
      darkTheme: previewTheme(AppThemeBuilder.dark(kPreviewSeed)),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Builder(builder: builder),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// 将当前画面写出为 preview/render 下的 PNG（配合 --update-goldens）。
Future<void> expectPreviewGolden(WidgetTester tester, String name) {
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('$kGoldenDir/$name.png'),
  );
}
