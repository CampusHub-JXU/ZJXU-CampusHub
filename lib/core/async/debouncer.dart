import 'dart:async';

/// 简单防抖：[run] 重置计时，仅最后一次在 [delay] 后执行。
class Debouncer {
  Debouncer(this.delay);

  /// 防抖窗口；可在运行期调整（对之后的 [run] 生效）。
  Duration delay;
  Timer? _timer;

  bool get isPending => _timer?.isActive ?? false;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
