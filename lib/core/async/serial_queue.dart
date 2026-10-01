import 'dart:async';

/// 同 isolate 的 Future 串行队列：任务按提交顺序逐个执行，前一个失败
/// 不影响后续任务（失败仍通过各自返回的 Future 抛给调用方）。
class SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then<T>((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// 丢弃排队状态（仅测试 reset 用）：之后提交的任务不再等待旧任务。
  void reset() => _tail = Future<void>.value();
}
