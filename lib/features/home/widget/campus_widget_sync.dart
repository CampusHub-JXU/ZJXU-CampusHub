import 'dart:async';

import '../../../core/notice/notice_sync_store.dart';
import '../../../core/semester/semester_calendar.dart';
import '../../../core/system_surface/campus_data_change_bus.dart';
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

  Duration _debounce = const Duration(milliseconds: 800);

  Timer? _timer;
  bool _started = false;

  /// 订阅影响模块数据的全局状态，变化时 debounce 同步（PRD §14）。
  ///
  /// 课表/成绩/考试/校园卡/电费在数据真正落库时由各自 service ping
  /// [CampusDataChangeBus]，这里统一消费；首页刷新路径也会显式 requestSync()。
  void start() {
    if (_started) return;
    _started = true;
    CampusDataChangeBus.instance.revision.addListener(requestSync);
    NoticeSyncStore.instance.unreadSummary.addListener(requestSync);
    SemesterCalendar.instance.semesterStartDate.addListener(requestSync);
    PersonalizationController.instance.fullDayCoursesEnabled.addListener(
      requestSync,
    );
  }

  /// 请求一次（debounced）同步；从缓存读取，不触发网络。
  ///
  /// debounce 归零时（测试环境）直接同步，不创建 Timer，避免测试结束后
  /// 仍有 pending timer 触发 binding 断言。
  void requestSync() {
    _timer?.cancel();
    _timer = null;
    if (_debounce == Duration.zero) {
      unawaited(_sync());
      return;
    }
    _timer = Timer(_debounce, () => unawaited(_sync()));
  }

  /// 测试用：调整 debounce 窗口（`Duration.zero` 走同步路径）。
  void debugSetDebounce(Duration value) => _debounce = value;

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
