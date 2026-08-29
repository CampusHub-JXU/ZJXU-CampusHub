import 'package:flutter/foundation.dart';

/// 首页单滚动页分区控制器：dock ScrollSpy 与锚点滚动的桥。
///
/// - [HomePage] 在滚动监听里调用 [updateZone]，把当前可视分区
///   （0 = 首屏区，1 = 功能区）同步进来；
/// - [AppShellPage] 监听本控制器，按 [zoneIndex] 决定 dock 高亮项；
/// - dock 点击「首页 / 功能」时经 [requestHome] / [requestFunction]，
///   由 HomePage 注入的 [scrollToTop] / [scrollToFunction] 实现
///   实际滚动（Scrollable.ensureVisible），禁止硬编码 offset。
class HomeZoneController extends ChangeNotifier {
  HomeZoneController._();

  static final HomeZoneController instance = HomeZoneController._();

  int _zoneIndex = 0; // 0 = 首屏区，1 = 功能区

  int get zoneIndex => _zoneIndex;

  /// 由 HomePage 注入；dock 触发的滚动实现。
  Future<void> Function()? scrollToTop;
  Future<void> Function()? scrollToFunction;

  /// HomePage 滚动监听回调：仅在实际变化时 notify。
  void updateZone(int index) {
    if (_zoneIndex == index) return;
    _zoneIndex = index;
    notifyListeners();
  }

  Future<void> requestHome() async => await scrollToTop?.call();

  Future<void> requestFunction() async => await scrollToFunction?.call();
}
