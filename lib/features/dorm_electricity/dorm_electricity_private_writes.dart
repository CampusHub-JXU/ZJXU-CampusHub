import 'dart:async';

/// 宿舍电费私有 prefs 变更的**同一 isolate 串行队列** + 受守卫写入。
///
/// 房间配置 / 余额缓存 / 预警设置 / 当日通知状态的写入必须单飞：A 的迟到
/// 写入若与 B 的显式保存交错（在 `await` 之间被切走），会把 A 的房间字段、
/// 缓存值或 opt-in 落到 B 的 owner 名下。所有私有变更都排在同一条 FIFO
/// 链上，队列内每次写入前后复核 owner + sessionRevision（必要时复核 owner
/// 标记），复核失败即放弃并回滚本次写入。
///
/// **只保证同一 isolate 内的串行**；WorkManager 后台 isolate 的读取仍依赖
/// `prefs.reload()` + 复核，不宣称跨 isolate 原子性。
///
/// **zone 契约（不可回退为 Future 链）**：
/// - 队列由一条 drain 循环驱动，一次只跑一个动作；**绝不 `await` 别的 zone
///   创建的 Future**（既没有 `Future<void>.value()` 种子，也没有
///   `await previous`）。已完成 Future 的迟到监听会回到它自己的 zone 调度
///   microtask（SDK `_Future._addListener`），而 widget 测试里 FakeAsync 区
///   之外的 zone（setUp / runAsync）不会被同步泵到——只要队列的推进依赖
///   「别的 zone 的 microtask」，`restoreCache` / `saveRoomConfig` 就会死锁。
/// - 动作由 drain 循环**在自己的 zone 里调用**：空闲后的第一个动作决定本轮
///   忙碌期的 zone，忙碌期内入队的动作（无论从哪个 zone 入队）都在该 zone
///   执行。这样 `runAsync` 写入 → fake zone 排队动作 → `runAsync` 写入的
///   混合序列不会互相等待对方 zone 的 microtask：整轮都在 `runAsync` 的真实
///   zone 里跑完。
/// - 调用方等待的 [Completer] 始终在**调用方 zone**里新建；completer 完成时
///   SDK 会切回监听方 zone，调用方无需泵别的 zone。
///
/// 残留边界（FakeAsync 固有限制，如实记录）：若本轮忙碌期由 **fake zone**
/// 的动作开启，且测试体在动作挂起时用 `runAsync` 阻塞等待，则 fake zone 的
/// microtask 不会被泵，队列只能在测试体恢复泵 fake zone 后继续。测试里
/// 切换 `runAsync` 前应先让 fake zone 的排队动作排空（仓库既有约定）。
class DormPrivateWrites {
  final List<_PendingPrivateWrite> _pending = <_PendingPrivateWrite>[];
  bool _draining = false;

  /// 基线重置代际：`debugReset` 使在途 drain 退出，避免旧用例的挂起动作
  /// 在下一个用例里「接管」新队列。
  int _generation = 0;

  /// 测试注入：串行队列内每次私有 prefs 写入的包装钩子（默认直接执行
  /// [write]）。测试可在写入前 await 制造确定性交错，或在写入完成后、
  /// 服务层写入后复核前翻转身份，验证放弃 / 回滚路径。钩子**必须**调用
  /// [write]，否则该次写入不会发生。
  ///
  /// 仅供服务层测试门面（`DormElectricityService.debugPrivateWriteHook`）
  /// 委托，不直接对外暴露。
  Future<void> Function(
    String operation,
    String key,
    Future<void> Function() write,
  )?
  debugWriteHook;

  /// 把一次私有变更排到串行队列尾部，返回其完成 Future。
  ///
  /// 队列自身永不因动作失败而断链（错误通过返回的 Future 抛给调用方），
  /// 后续动作不会被前一个失败动作卡住。
  Future<void> serialize(Future<void> Function() action) {
    final completer = Completer<void>();
    _pending.add(_PendingPrivateWrite(action, completer));
    if (!_draining) {
      _draining = true;
      // 同步启动本轮 drain：它留在当前 zone 里，后续动作由它在本 zone 调用。
      unawaited(_drain(_generation));
    }
    return completer.future;
  }

  /// 逐个执行排队动作，直到本轮忙碌期结束（或基线重置换了代际）。
  Future<void> _drain(int generation) async {
    while (generation == _generation && _pending.isNotEmpty) {
      final entry = _pending.removeAt(0);
      try {
        await entry.action();
        entry.completer.complete();
      } catch (error, stackTrace) {
        entry.completer.completeError(error, stackTrace);
      }
    }
    if (generation == _generation) _draining = false;
  }

  Future<void> _write(
    String operation,
    String key,
    Future<void> Function() write,
  ) {
    final hook = debugWriteHook;
    if (hook == null) return write();
    return hook(operation, key, write);
  }

  /// 串行队列内的一次受守卫私有写入：写入前复核 → 执行 → 写入后复核；
  /// 写入后复核失败时回滚本次写入（[rollback]），绝不让身份变化后的值留在
  /// 磁盘上被新身份采纳。
  Future<bool> guarded({
    required String operation,
    required String key,
    required bool Function() verify,
    required Future<void> Function() write,
    Future<void> Function()? rollback,
  }) async {
    if (!verify()) return false;
    await _write(operation, key, write);
    if (verify()) return true;
    await rollback?.call();
    return false;
  }

  /// 清空队列与测试钩子（测试基线重置走服务层 `debugReset`）。
  ///
  /// 推进代际让在途 drain 退出：旧用例里挂起的动作绝不会消费新用例的队列。
  void debugReset() {
    _generation++;
    _pending.clear();
    _draining = false;
    debugWriteHook = null;
  }
}

class _PendingPrivateWrite {
  const _PendingPrivateWrite(this.action, this.completer);

  final Future<void> Function() action;
  final Completer<void> completer;
}
