import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_wallpaper_backdrop.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/glass_nav_bar.dart';
import '../../shared/widgets/plain_list.dart';
import 'widgets/personalization_background_section.dart';
import 'widgets/personalization_effects_section.dart';
import 'widgets/personalization_home_section.dart';
import 'widgets/personalization_icon_section.dart';
import 'widgets/theme_settings_sections.dart';

/// 外观与个性化（合并主题模式、色彩、壁纸、效果、首页内容与图标设置）。
///
/// 顶部移除占位的缩略预览框，改为右上角「按住预览」：按住时全屏淡入
/// 1:1 真实首页实体（壁纸 / 流体 Shader / 首页内容 / 液态玻璃 Dock），松开
/// 立即回到原滚动位置继续调整。
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key, this.homeSceneBuilder});

  /// 真实首页场景构建器（app 层注入 `HomeSurfaceScene`）。
  final WidgetBuilder? homeSceneBuilder;

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _previewController;
  late final Animation<double> _previewFade;
  bool _overlayMounted = false;
  int? _activePointer;

  @override
  void initState() {
    super.initState();
    _previewController = AnimationController(
      vsync: this,
      duration: AppMotion.quick,
      reverseDuration: AppMotion.quick,
    );
    _previewFade = CurvedAnimation(
      parent: _previewController,
      curve: AppMotion.standard,
      reverseCurve: AppMotion.standardReverse,
    );
    _previewController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted && _overlayMounted) {
        setState(() => _overlayMounted = false);
      }
    });
  }

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  void _startPreview(int pointer) {
    _activePointer = pointer;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.quick;
    _previewController.duration = duration;
    _previewController.reverseDuration = duration;
    HapticFeedback.selectionClick();
    if (!_overlayMounted) {
      setState(() => _overlayMounted = true);
    }
    if (duration == Duration.zero) {
      _previewController.value = 1;
    } else {
      _previewController.forward();
    }
  }

  void _stopPreview(int pointer) {
    if (_activePointer != pointer) return;
    _activePointer = null;
    if (_previewController.value == 0 || AppMotion.reduced(context)) {
      _previewController.value = 0;
      if (_overlayMounted) {
        setState(() => _overlayMounted = false);
      }
      return;
    }
    _previewController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Scaffold(
          appBar: AppAppBar(
            title: const Text('外观与个性化'),
            leading: const BackButton(),
            actions: [
              _HoldPreviewButton(
                onPointerDown: (event) => _startPreview(event.pointer),
                onPointerUp: (event) => _stopPreview(event.pointer),
                onPointerCancel: (event) => _stopPreview(event.pointer),
              ),
            ],
          ),
          body: CustomScrollView(
            key: const Key('personalization_scroll'),
            slivers: const [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  kPlainListGutter,
                  12,
                  kPlainListGutter,
                  32,
                ),
                sliver: SliverList(
                  delegate: SliverChildListDelegate.fixed([
                    ThemeSettingsSections(),
                    SizedBox(height: kPlainListGroupGap),
                    PersonalizationBackgroundSection(),
                    SizedBox(height: kPlainListGroupGap),
                    PersonalizationEffectsSection(),
                    SizedBox(height: kPlainListGroupGap),
                    PersonalizationHomeSection(),
                    SizedBox(height: kPlainListGroupGap),
                    PersonalizationIconSection(),
                  ]),
                ),
              ),
            ],
          ),
        ),
        if (_overlayMounted)
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: _previewFade,
                child: _HomeEntityPreviewOverlay(
                  homeSceneBuilder: widget.homeSceneBuilder,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _HoldPreviewButton extends StatelessWidget {
  const _HoldPreviewButton({
    required this.onPointerDown,
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  final PointerDownEventListener onPointerDown;
  final PointerUpEventListener onPointerUp;
  final PointerCancelEventListener onPointerCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        label: '按住预览首页',
        child: Listener(
          key: const Key('appearance_hold_preview'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: onPointerDown,
          onPointerUp: onPointerUp,
          onPointerCancel: onPointerCancel,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Center(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.72),
                  shape: const StadiumBorder(),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        size: 16,
                        color: cs.onSurface,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '按住预览',
                        style: context.appText.meta.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeEntityPreviewOverlay extends StatelessWidget {
  const _HomeEntityPreviewOverlay({required this.homeSceneBuilder});

  final WidgetBuilder? homeSceneBuilder;

  @override
  Widget build(BuildContext context) {
    return BackdropGroup(
      child: Scaffold(
        extendBody: true,
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const AppWallpaperBackdrop(),
            SafeArea(
              bottom: false,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 110),
                child:
                    homeSceneBuilder?.call(context) ?? const SizedBox.shrink(),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: GlassNavBar(
              currentIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                GlassNavBarDestination(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home,
                  label: '主页',
                ),
                GlassNavBarDestination(
                  icon: Icons.widgets_outlined,
                  selectedIcon: Icons.widgets,
                  label: '功能',
                ),
                GlassNavBarDestination(
                  icon: Icons.person_outline,
                  selectedIcon: Icons.person,
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
