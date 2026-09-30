import 'package:flutter/material.dart';

import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/plain_list.dart';
import 'widgets/appearance_preview.dart';
import 'widgets/personalization_background_section.dart';
import 'widgets/personalization_effects_section.dart';
import 'widgets/personalization_home_section.dart';

/// 预览区的高度区间：页面下滑时从 [kPersonalizationPreviewMaxHeight]
/// 平滑收缩到 [kPersonalizationPreviewMinHeight]，随后固定在顶部。
const double kPersonalizationPreviewMaxHeight = 300;
const double kPersonalizationPreviewMinHeight = 120;

/// 首页与界面个性化设置：顶部固定预览（主页 / 功能 / 我的）+
/// 壁纸 / 效果 / 首页内容三个分组。
class PersonalizationPage extends StatefulWidget {
  const PersonalizationPage({super.key, this.homeSceneBuilder});

  /// 真实首页场景构建器（app 层注入 `HomeSurfaceScene`）。
  final WidgetBuilder? homeSceneBuilder;

  @override
  State<PersonalizationPage> createState() => _PersonalizationPageState();
}

class _PersonalizationPageState extends State<PersonalizationPage> {
  AppearancePreviewScene _scene = AppearancePreviewScene.home;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(title: const Text('个性化'), leading: const BackButton()),
      body: CustomScrollView(
        key: const Key('personalization_scroll'),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _PreviewHeaderDelegate(
              scene: _scene,
              homeSceneBuilder: widget.homeSceneBuilder,
              background: Theme.of(context).scaffoldBackgroundColor,
              onSceneChanged: (scene) => setState(() => _scene = scene),
            ),
          ),
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(
              kPlainListGutter,
              12,
              kPlainListGutter,
              32,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate.fixed([
                PersonalizationBackgroundSection(),
                SizedBox(height: kPlainListGroupGap),
                PersonalizationEffectsSection(),
                SizedBox(height: kPlainListGroupGap),
                PersonalizationHomeSection(),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewHeaderDelegate extends SliverPersistentHeaderDelegate {
  _PreviewHeaderDelegate({
    required this.scene,
    required this.homeSceneBuilder,
    required this.background,
    required this.onSceneChanged,
  });

  final AppearancePreviewScene scene;
  final WidgetBuilder? homeSceneBuilder;
  final Color background;
  final ValueChanged<AppearancePreviewScene> onSceneChanged;

  static const double _topPadding = 8;
  static const double _switcherHeight = 56;
  static const double _chrome = _topPadding + _switcherHeight;

  @override
  double get maxExtent => kPersonalizationPreviewMaxHeight + _chrome;

  @override
  double get minExtent => kPersonalizationPreviewMinHeight + _chrome;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final previewHeight = (maxExtent - shrinkOffset - _chrome).clamp(
      kPersonalizationPreviewMinHeight,
      kPersonalizationPreviewMaxHeight,
    );
    return ColoredBox(
      color: background,
      child: Column(
        children: [
          const SizedBox(height: _topPadding),
          SizedBox(
            key: const Key('personalization_preview'),
            height: previewHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kPlainListGutter),
              child: AppearancePreview(
                maxHeight: previewHeight,
                scene: scene,
                homeSceneBuilder: homeSceneBuilder,
              ),
            ),
          ),
          SizedBox(
            height: _switcherHeight,
            child: Center(
              child: SegmentedButton<AppearancePreviewScene>(
                key: const Key('personalization_scene_segments'),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(
                    value: AppearancePreviewScene.home,
                    label: Text('主页'),
                  ),
                  ButtonSegment(
                    value: AppearancePreviewScene.functions,
                    label: Text('功能'),
                  ),
                  ButtonSegment(
                    value: AppearancePreviewScene.my,
                    label: Text('我的'),
                  ),
                ],
                selected: {scene},
                onSelectionChanged: (s) => onSceneChanged(s.first),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_PreviewHeaderDelegate oldDelegate) =>
      scene != oldDelegate.scene ||
      homeSceneBuilder != oldDelegate.homeSceneBuilder ||
      background != oldDelegate.background;
}
