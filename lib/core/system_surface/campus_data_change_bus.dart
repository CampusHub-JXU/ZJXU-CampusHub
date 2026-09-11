import 'package:flutter/foundation.dart';

/// 校园数据变更广播（PRD 0.7.0 §14）。
///
/// feature 侧只在缓存数据真正变化后 ping 一次，跨 feature 的消费方
/// （桌面组件同步、首页聚合）据此重建投影。只广播「变了」不携带数据，
/// 业务模型与凭据不穿透到 core 层。
class CampusDataChangeBus {
  CampusDataChangeBus._();

  static final CampusDataChangeBus instance = CampusDataChangeBus._();

  /// 自增版本号：监听它等价于监听「任一校园数据已更新」。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void notifyChanged() {
    revision.value++;
  }

  @visibleForTesting
  void debugReset() {
    revision.value = 0;
  }
}
