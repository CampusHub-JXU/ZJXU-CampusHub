import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/shared/widgets/app_app_bar.dart';
import 'package:jxu_campus_hub/shared/widgets/app_icon_badge.dart';
import 'package:jxu_campus_hub/shared/widgets/app_tile_surface.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';
import 'package:jxu_campus_hub/shared/widgets/frost_grain.dart';

import '../helpers/preview_support.dart';

/// Issue #47 稀疏闪粉的**专用**预览（独立于 `preview_render_test.dart`，
/// 避免与其它 PR 的预览场景集互相干扰）。
///
/// 渲染的是真实组件（`AppTileSurface` / `AppAppBar` / `GlassContainer`），
/// 覆盖浅 / 深色 × DPR 1 / 2 / 3，用来人工判断「不再像皮革 / 砂纸」。
///
/// `flutter test` 默认全部 skip；渲染：
///   $env:JXU_PREVIEW_RENDER=1
///   flutter test --update-goldens test/preview/sparse_acrylic_preview_test.dart
/// 产物写到 `preview/render/sparse_grain/`（已 gitignore）。
///
/// **模型没有图像输入**，本文件只产出可人工审阅的 PNG，不代表任何「看起来像 / 不像
/// 皮革」的结论——那是维护者的人工视觉 gate。
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';
  const goldenDir = '../../preview/render/sparse_grain';
  final assetExists = File('assets/textures/frost_grain_peaks.png')
      .existsSync();

  setUpAll(() async {
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  Future<void> pumpScene(
    WidgetTester tester,
    WidgetBuilder builder, {
    required Brightness brightness,
    required double dpr,
    Size logicalSize = const Size(412, 620),
  }) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = Size(
      logicalSize.width * dpr,
      logicalSize.height * dpr,
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
    // Image.asset 的真实解码在 FakeAsync 区内不会完成。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  void scene(
    String name,
    Widget Function(Brightness brightness) builder, {
    Size logicalSize = const Size(412, 620),
    bool requireAsset = false,
  }) {
    for (final brightness in Brightness.values) {
      final suffix = brightness == Brightness.dark ? 'dark' : 'light';
      for (final dpr in const [1.0, 2.0, 3.0]) {
        final dprLabel = dpr.toInt();
        testWidgets('preview: ${name}_${suffix}_dpr$dprLabel', (tester) async {
          if (!renderEnabled) return;
          if (requireAsset && !assetExists) return;
          await pumpScene(
            tester,
            (_) => builder(brightness),
            brightness: brightness,
            dpr: dpr,
            logicalSize: logicalSize,
          );
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('$goldenDir/${name}_${suffix}_dpr$dprLabel.png'),
          );
        }, skip: !renderEnabled);
      }
    }
  }

  scene('tiles', (b) => const _TilesScene());
  scene('appbar', (b) => const _AppBarScene());
  scene(
    'overlay',
    (b) => const _OverlayScene(),
    logicalSize: const Size(412, 520),
  );
  scene(
    'texture_raw',
    (b) => _TextureSwatchScene(
      isDark: b == Brightness.dark,
      showNative: assetExists,
    ),
    logicalSize: const Size(412, 620),
    requireAsset: true,
  );
}

// ── 场景 ────────────────────────────────────────────────────────────────────

class _Gradient extends StatelessWidget {
  const _Gradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF8B1A2D),
            Color(0xFFD4AF37),
            Color(0xFF1565C0),
            Color(0xFF2EA567),
          ],
        ),
      ),
    );
  }
}

Widget _tile(
  BuildContext context,
  String title,
  String subtitle,
  IconData icon,
  Color accent,
) {
  return AppTileSurface(
    onTap: () {},
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: Row(
      children: [
        AppIconBadge(
          icon: icon,
          accentColor: accent,
          size: AppIconBadgeSize.small,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 首页功能区式的磁贴网格（十几块亚克力磁贴，验证密集表面上的颗粒观感）。
class _TilesScene extends StatelessWidget {
  const _TilesScene();

  @override
  Widget build(BuildContext context) {
    return BackdropGroup(
      child: Stack(
        children: [
          const Positioned.fill(child: _Gradient()),
          Positioned.fill(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '功能区 · 稀疏闪粉磁贴',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '正文清晰度与颗粒密度的人工对照',
                    style: TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  _tile(
                    context,
                    '课表',
                    '第 5 周 · 下一节 08:00',
                    Icons.calendar_month_rounded,
                    const Color(0xFF8B1A2D),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < 5; i++) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _tile(
                            context,
                            i.isEven ? '成绩' : '考试',
                            i.isEven ? 'GPA 3.62' : '2 场待考',
                            i.isEven
                                ? Icons.school_outlined
                                : Icons.event_note_outlined,
                            i.isEven
                                ? const Color(0xFFD4AF37)
                                : const Color(0xFF1565C0),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _tile(
                            context,
                            i.isEven ? '校园卡' : '宿舍电费',
                            i.isEven ? '38.20 元' : '27.4 度',
                            i.isEven
                                ? Icons.account_balance_wallet_outlined
                                : Icons.bolt_outlined,
                            i.isEven
                                ? const Color(0xFF2EA567)
                                : const Color(0xFF8B1A2D),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶栏毛玻璃：内容滚到 AppAppBar 之下，验证顶栏颗粒 + 文字。
class _AppBarScene extends StatelessWidget {
  const _AppBarScene();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppAppBar(title: const Text('顶栏毛玻璃')),
      body: Stack(
        children: [
          const Positioned.fill(child: _Gradient()),
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 120, 16, 24),
            children: [
              for (var i = 0; i < 10; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppTileSurface(
                    onTap: () {},
                    padding: const EdgeInsets.all(14),
                    child: Text('列表项 $i · 内容滚到顶栏之下应被磨砂'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 玻璃弹层：确认弹窗式的 overlay 档材质（用户截图里最像皮革的那种表面）。
class _OverlayScene extends StatelessWidget {
  const _OverlayScene();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: _Gradient()),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: GlassContainer(
              tier: GlassTier.overlay,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '确认退出登录？',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '退出后需要重新验证统一认证与教务系统，'
                    '本地缓存与课表数据会保留。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () {}, child: const Text('取消')),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: () {}, child: const Text('退出登录')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 贴图对照：三个同尺寸、同填充、同圆角的色块，**只差颗粒层**，
/// 这样「无颗粒 vs 真实配方」的差异可以被程序化测量（也便于人眼直接看稀疏度）。
///
/// 第三个（1:1 原生分辨率）只在贴图资源存在时渲染——基线 worktree（master）没有
/// 该资源，本文件在那里也要能跑，用来产出「改动前」的对照图。
class _TextureSwatchScene extends StatelessWidget {
  const _TextureSwatchScene({required this.isDark, required this.showNative});

  final bool isDark;
  final bool showNative;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = isDark
        ? scheme.surfaceContainerLow
        : scheme.surfaceContainerLowest;
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('稀疏闪粉贴图对照 · ${isDark ? '深色' : '浅色'}'),
          const SizedBox(height: 16),
          _panel(context, '填充（无颗粒）', fill, null),
          const SizedBox(height: 16),
          _panel(
            context,
            '填充 + 颗粒（真实配方 · 256dp 周期）',
            fill,
            frostGrainImage(isDark: isDark),
          ),
          if (showNative) ...[
            const SizedBox(height: 16),
            _panel(
              context,
              '填充 + 颗粒（1:1 原生分辨率，看结构）',
              fill,
              const DecorationImage(
                image: AssetImage('assets/textures/frost_grain_peaks.png'),
                repeat: ImageRepeat.repeat,
                filterQuality: FilterQuality.low,
                onError: _ignoreMissingAsset,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _panel(
    BuildContext context,
    String label,
    Color fill,
    DecorationImage? image,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        Container(
          height: 120,
          padding: const EdgeInsets.all(12),
          alignment: Alignment.bottomLeft,
          decoration: ShapeDecoration(
            color: fill,
            image: image,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: Text(
            '正文可读性 · 128.50 元',
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black87,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// 缺资源时静默（基线 worktree 里没有该贴图）。
void _ignoreMissingAsset(Object exception, StackTrace? stackTrace) {}
