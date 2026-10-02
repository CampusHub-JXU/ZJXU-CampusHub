import 'dart:async';

import 'package:flutter/foundation.dart';

/// 全局「页面转场进行中」信号。
///
/// 应用统一的页面转场（`app_theme_builder.dart` 的 `_SharedAxisPageTransition`）
/// 在每次 push / pop 动画期间持有一次 [acquire]，动画结束或页面销毁时
/// [release]。下面几处据此在转场的 ~450ms 内让路，避免与转场抢帧：
///
/// * 首页壁纸 Shader 暂停推进（转场帧预算留给转场本身）；
/// * 首页 / 我的把返回后的刷新 / 数据变更重建推迟到转场结束之后（[whenIdle]）。
///
/// 计数制：多个转场重叠（连续 push、pop 打断 push）时，只有全部结束才算空闲。
///
/// **看门狗**：让路只是「锦上添花」，绝不能反过来让首页永远不刷新 / 壁纸永远
/// 定格。任何一次登记漏了配对 [release]（例如某个转场的动画被中途冻结），
/// 超过 [maxHold] 没有任何新的 acquire / release 就视为陈旧：[isBusy] 报告空闲，
/// [whenIdle] 最多等 [maxHold]，下一次 [acquire] 会清掉陈旧计数。
class PageTransitionActivity {
  PageTransitionActivity._();

  static final PageTransitionActivity instance = PageTransitionActivity._();

  /// 单次转场约 450ms；留足余量，仍远小于用户可感知的「卡死」。
  static const Duration defaultMaxHold = Duration(seconds: 2);

  Duration _maxHold = defaultMaxHold;

  /// 原始计数信号：只要还有未配对的登记就为 true（含陈旧登记）。
  /// 消费方判断「要不要让路」请用 [isBusy]，等待请用 [whenIdle]。
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastActivity = Duration.zero;
  int _holds = 0;

  void _touch() => _lastActivity = _clock.elapsed;

  bool get _isStale => _holds > 0 && _clock.elapsed - _lastActivity > _maxHold;

  /// 当前是否有**未过期**的页面转场正在进行。
  bool get isBusy => active.value && !_isStale;

  /// 清掉陈旧登记（看门狗触发）。
  void _expireIfStale() {
    if (!_isStale) return;
    _holds = 0;
    active.value = false;
  }

  /// 声明一次转场开始，返回前须配对 [release]。
  void acquire() {
    _expireIfStale();
    _touch();
    _holds++;
    if (_holds == 1) active.value = true;
  }

  /// 声明一次转场结束；多余的 release 被忽略。
  void release() {
    if (_holds == 0) return;
    _touch();
    _holds--;
    if (_holds == 0) active.value = false;
  }

  /// 转场空闲时完成：当前没有转场则立即完成，否则等到最后一个转场结束；
  /// 最多等 [maxHold]（看门狗），超时同样完成。
  Future<void> whenIdle() {
    _expireIfStale();
    if (!active.value) return Future<void>.value();
    final completer = Completer<void>();
    Timer? watchdog;
    late VoidCallback listener;
    void finish() {
      if (completer.isCompleted) return;
      active.removeListener(listener);
      watchdog?.cancel();
      completer.complete();
    }

    listener = () {
      if (!active.value) finish();
    };
    active.addListener(listener);
    watchdog = Timer(_maxHold, () {
      _expireIfStale();
      finish();
    });
    return completer.future;
  }

  @visibleForTesting
  set debugMaxHold(Duration value) => _maxHold = value;

  @visibleForTesting
  void debugReset() {
    _holds = 0;
    _maxHold = defaultMaxHold;
    _lastActivity = _clock.elapsed;
    active.value = false;
  }
}
