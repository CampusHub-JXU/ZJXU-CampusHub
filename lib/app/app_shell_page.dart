import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/glass_style_controller.dart';
import '../features/home/home_zone_controller.dart';
import '../shared/widgets/glass_nav_bar.dart';

/// 底部 dock 的三个 destination 与路由 branch 的对应关系：
/// - 0「主页」→ branch0 的首屏区（zone 0）；
/// - 1「功能」→ branch0 的功能区锚点段落（zone 1）；
/// - 2「我的」→ branch1。
class AppShellPage extends StatefulWidget {
  const AppShellPage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

class _AppShellPageState extends State<AppShellPage> {
  @override
  void initState() {
    super.initState();
    GlassStyleController.instance.restore();
    // ScrollSpy：首页分区变化时刷新 dock 高亮。
    HomeZoneController.instance.addListener(_onZoneChanged);
  }

  @override
  void dispose() {
    HomeZoneController.instance.removeListener(_onZoneChanged);
    super.dispose();
  }

  void _onZoneChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// dock 当前高亮项：
  /// - 在 branch1（我的）时固定高亮第 2 项；
  /// - 在 branch0（首页单滚动页）时按 ScrollSpy 分区高亮 主页/功能。
  int get _highlightIndex {
    if (widget.navigationShell.currentIndex == 1) return 2;
    final zone = HomeZoneController.instance.zoneIndex;
    return zone <= 0 ? 0 : 1;
  }

  /// dock 点击状态机：
  /// - 主页：不在 branch0 → goBranch(0)（不传 initialLocation，保留
  ///   branch0 已有栈与滚动位置），postFrame 滚到页面顶部；
  ///   已在 branch0 → 直接滚到顶部。
  /// - 功能：不在 branch0 → goBranch(0)，postFrame 滚到功能区锚点；
  ///   已在 branch0 → 直接滚到锚点。
  /// - 我的：goBranch(1)，重复点击时回到 branch 初始 location（旧行为）。
  void _onDestinationSelected(int index) {
    final shell = widget.navigationShell;
    switch (index) {
      case 0:
        _ensureHomeBranchThen(() => HomeZoneController.instance.requestHome());
      case 1:
        _ensureHomeBranchThen(
          () => HomeZoneController.instance.requestFunction(),
        );
      case 2:
        shell.goBranch(1, initialLocation: shell.currentIndex == 1);
    }
  }

  /// 保证落在 branch0 后再执行滚动请求。
  ///
  /// branch0 的 IndexedStack 保活使 HomePage 始终挂在树上，滚动实现
  /// 总是可用；先 goBranch 再 postFrame 是为了让路由切换先落地。
  void _ensureHomeBranchThen(Future<void> Function() request) {
    final shell = widget.navigationShell;
    if (shell.currentIndex != 0) {
      // 不传 initialLocation：恢复 branch0 上次的位置而非重置。
      shell.goBranch(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        request();
      });
    } else {
      request();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: widget.navigationShell,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: GlassNavBar(
            currentIndex: _highlightIndex,
            onDestinationSelected: _onDestinationSelected,
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
    );
  }
}

/// 分支容器：替代 `indexedStack` 的 IndexedStack，切换时新分支在旧分支
/// **之上**淡入并轻微侧移，旧分支保持可见直到被完全盖住——两页都自带
/// 不透明壁纸背景，因此过渡是页与页的交叉淡化，不会透出 Scaffold 底色
/// （旧实现整体淡入单个 shell，暗色下会闪一下黑）。
///
/// 非当前、非过渡中的分支 Offstage + TickerMode 关闭，与 IndexedStack
/// 一样保活状态且不跑动画 / Shader ticker。
class AppShellBranchContainer extends StatefulWidget {
  const AppShellBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  State<AppShellBranchContainer> createState() =>
      _AppShellBranchContainerState();
}

class _AppShellBranchContainerState extends State<AppShellBranchContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  )..addStatusListener(_onStatus);

  late int _current = widget.currentIndex;
  int? _previous;
  double _slideFrom = 0;

  @override
  void didUpdateWidget(covariant AppShellBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex == _current) return;
    // 进入更高 index 的分支（主页→我的）从右侧轻推入；返回则从左侧。
    _slideFrom = widget.currentIndex > _current ? 0.04 : -0.04;
    _previous = _current;
    _current = widget.currentIndex;
    _controller.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous != null) {
      setState(() => _previous = null);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    final previous = _previous;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          if (i != _current)
            Offstage(
              offstage: i != previous,
              child: TickerMode(
                enabled: i == previous,
                child: IgnorePointer(child: widget.children[i]),
              ),
            ),
        // 当前分支最后绘制，盖在过渡中的旧分支之上。
        FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(_slideFrom, 0),
              end: Offset.zero,
            ).animate(curved),
            child: widget.children[_current],
          ),
        ),
      ],
    );
  }
}
