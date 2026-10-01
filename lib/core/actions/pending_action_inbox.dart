import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 「冷启动 / 运行期动作 → 挂起到导航就绪 → 下一帧投递」的共享收件箱，
/// 供快捷方式与深链入口复用。
///
/// 只保留**最新**一条挂起动作；就绪信号翻转为 true 时由 [flush] 补发，
/// 投递放到 post-frame 回调里并主动 `scheduleFrame`，避免在无帧的空闲期卡住。
class PendingActionInbox {
  PendingActionInbox({required this.deliver, this.canDeliver});

  /// post-frame 时真正执行动作。
  final void Function(String action) deliver;

  /// 可选前置条件（如分发回调尚未注入）：不满足时**保留**挂起动作，等待下次 [flush]。
  final bool Function()? canDeliver;

  ValueListenable<bool>? navigationReady;

  String? _pending;
  bool _listening = false;

  bool get isReady => navigationReady?.value ?? false;

  /// 在 [navigationReady] 上注册 [flush] 监听（仅一次；信号为空则不注册）。
  void ensureListening() {
    if (_listening) return;
    final ready = navigationReady;
    if (ready == null) return;
    ready.addListener(flush);
    _listening = true;
  }

  /// 记录最新动作并尝试立即投递。
  void queue(String action) {
    _pending = action;
    flush();
  }

  void flush() {
    final action = _pending;
    if (action == null || !isReady) return;
    if (canDeliver != null && !canDeliver!()) return;

    _pending = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => deliver(action));
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 测试复位：摘掉监听并清空状态。
  void reset() {
    if (_listening) navigationReady?.removeListener(flush);
    _listening = false;
    navigationReady = null;
    _pending = null;
  }
}
