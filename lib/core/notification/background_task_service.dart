import 'package:timezone/data/latest.dart' as tz_data;
import 'package:workmanager/workmanager.dart';

/// 通用后台任务调度服务（WorkManager 薄封装）。
///
/// core 层只保留与业务无关的调度能力：初始化时区与 WorkManager、
/// 注册/取消周期任务。具体业务任务（电费检查、第二课堂监控等）
/// 由各 feature 承载，回调 dispatcher 与任务注册统一在 app 组合层接线。
class BackgroundTaskService {
  BackgroundTaskService._();
  static final instance = BackgroundTaskService._();

  bool _initialized = false;

  /// 初始化时区数据与 WorkManager。
  ///
  /// [callbackDispatcher] 由外部注入（app 层组合），core 不感知具体业务。
  Future<void> initialize({required void Function() callbackDispatcher}) async {
    if (_initialized) return;

    tz_data.initializeTimeZones();

    await Workmanager().initialize(callbackDispatcher);

    _initialized = true;
  }

  /// 注册周期性后台任务（同名任务已存在时保持原配置不变）。
  Future<void> registerPeriodicTask({
    required String uniqueName,
    required Duration frequency,
    Constraints? constraints,
  }) async {
    await Workmanager().registerPeriodicTask(
      uniqueName,
      uniqueName,
      frequency: frequency,
      constraints: constraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// 按唯一名取消已注册的后台任务。
  Future<void> cancelTask(String uniqueName) async {
    await Workmanager().cancelByUniqueName(uniqueName);
  }
}
