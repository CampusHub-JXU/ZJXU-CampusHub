import 'dart:async';

import 'package:flutter/foundation.dart';

/// 全局「页面转场进行中」信号。
///
/// 应用统一的页面转场（`app_theme_builder.dart` 的 `_SlideFadePageTransition`）
/// 在每次 push / pop 动画期间持有一次 [acquire]，动画结束或页面销毁时
/// [release]。下面几处据此在转场的 ~220ms 内让路，避免与转场抢帧：
///
/// * 首页壁纸 Shader 暂停推进（转场帧预算留给转场本身）；
/// * 首页把返回后的刷新 / 数据变更重建推迟到转场结束之后（[whenIdle]）。
///
/// 计数制：多个转场重叠（连续 push、pop 打断 push）时，只有全部结束才算空闲。
class PageTransitionActivity {
  PageTransitionActivity._();

  static final PageTransitionActivity instance = PageTransitionActivity._();

  /// 是否有页面转场正在进行。
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  int _holds = 0;

  /// 声明一次转场开始，返回前须配对 [release]。
  void acquire() {
    _holds++;
    if (_holds == 1) active.value = true;
  }

  /// 声明一次转场结束；多余的 release 被忽略。
  void release() {
    if (_holds == 0) return;
    _holds--;
    if (_holds == 0) active.value = false;
  }

  /// 转场空闲时完成：当前没有转场则立即完成，否则等到最后一个转场结束。
  Future<void> whenIdle() {
    if (!active.value) return Future<void>.value();
    final completer = Completer<void>();
    void listener() {
      if (active.value) return;
      active.removeListener(listener);
      completer.complete();
    }

    active.addListener(listener);
    return completer.future;
  }

  @visibleForTesting
  void debugReset() {
    _holds = 0;
    active.value = false;
  }
}
