import 'dart:async';

import '../../../core/notice/notice_sync_store.dart';
import '../../../core/semester/semester_calendar.dart';
import '../../../core/system_surface/campus_widget_bridge.dart';
import '../../../core/theme/personalization_controller.dart';
import 'campus_widget_projection.dart';

/// 桌面组件刷新调度（PRD §14）。
///
/// 触发点（缓存恢复 / 前台 / 课表 / 成绩考试 / 校园卡 / 电费 / 通知变化）统一
/// 走这里 debounce，避免高频写原生状态。
class CampusWidgetSync {
  CampusWidgetSync._();

  static final CampusWidgetSync instance = CampusWidgetSync._();

  static const _debounce = Duration(milliseconds: 800);

  Timer? _timer;
  bool _started = false;

  /// 订阅影响模块数据的全局状态，变化时 debounce 同步（PRD §14）。
  /// 网络刷新（课表/校园卡/电费/考试）由 HomePage 完成后显式 requestSync()。
  void start() {
    if (_started) return;
    _started = true;
    NoticeSyncStore.instance.unreadSummary.addListener(requestSync);
    SemesterCalendar.instance.semesterStartDate.addListener(requestSync);
    PersonalizationController.instance.fullDayCoursesEnabled.addListener(
      requestSync,
    );
  }

  /// 请求一次（debounced）同步；从缓存读取，不触发网络。
  void requestSync() {
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(_sync()));
  }

  /// 立即同步（测试/关键路径用）。
  Future<void> syncNow() => _sync();

  Future<void> _sync() async {
    try {
      final projection = buildCampusWidgetProjection();
      await CampusWidgetBridge.instance.pushSnapshot(projection.toMap());
    } catch (_) {
      // 桌面同步失败不影响 App 主流程。
    }
  }

  void debugReset() {
    _timer?.cancel();
    _timer = null;
  }
}
