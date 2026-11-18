import 'package:material_ui/material_ui.dart';

/// 状态视图（空态 / 错误态 / 登录引导）的统一入场动画。
///
/// 三个状态视图在业务页面里通常整块替换出现（loading → 空态、内容 → 错误
/// 态、未登录 → 登录引导），此前都是裸 return，切换瞬间完成、非常生硬。
/// 这里收敛为「淡入 + 轻微上浮」，与 login_shell.dart:271 的弹层转场
/// （240ms easeOutCubic，Offset(0, 0.04)）保持同一节奏。
///
/// 只在首次挂载时播放一次：状态视图常随数据刷新一起 rebuild，父级重建
/// 不重播，避免闪烁。若父级用 AnimatedSwitcher 或对 child 换了 key，
/// 会重新挂载从而自然重播一次，正是状态切换时想要的效果。
class AppStateViewTransition extends StatefulWidget {
  const AppStateViewTransition({super.key, required this.child});

  final Widget child;

  /// 与 login_shell 弹层转场对齐的时长。
  static const Duration duration = Duration(milliseconds: 240);

  /// 淡入起点。
  ///
  /// 刻意不从 0 开始：RenderOpacity 在 alpha 归零时会直接跳过命中测试，
  /// 动画首帧里的按钮（「重试」「去选择寝室」等）将点不动，widget 测试与
  /// 无障碍都会受影响。2% 在观感上等同于全透明，但保住了可命中性。
  static const double fadeFloor = 0.02;

  @override
  State<AppStateViewTransition> createState() => _AppStateViewTransitionState();
}

class _AppStateViewTransitionState extends State<AppStateViewTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppStateViewTransition.duration,
  );

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  late final Animation<double> _fade = Tween<double>(
    begin: AppStateViewTransition.fadeFloor,
    end: 1,
  ).animate(_curve);

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.04),
    end: Offset.zero,
  ).animate(_curve);

  /// 是否已读取过「减弱动效」设置（只在首次挂载时判定一次）。
  bool _reduceMotionResolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 尊重系统「减弱动效」设置：直接落到终态，不播放动画。
    // 依赖 MediaQuery 的读取必须放在 didChangeDependencies——放在 initState
    // 里会在 inherited 依赖建立前调用 dependOnInheritedWidget，直接抛断言。
    if (_reduceMotionResolved) return;
    _reduceMotionResolved = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
