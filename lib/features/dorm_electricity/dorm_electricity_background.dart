// 寝室电费后台任务逻辑。
//
// 自 core/notification/background_task_service.dart 下沉（架构反转）：
// core 只保留通用 WorkManager 调度能力，电费检查与通知业务由本文件承载，
// 统一通过 BackgroundTaskService 的通用 API 注册/取消任务。
//
// **单账号归属（fail closed）**：后台 isolate 不得从全局 prefs 直接读取
// 「当前用户」的电费预警设置——那会把 A 的 opt-in 与缓存透给 B。这里先
// 用 [UnifiedAuthService.restoreSession]（`syncWebViewCookies: false`，仅恢复
// 持久会话元数据：不触网、不自动登录、不碰 WebView）拿到可信账号，再要求
// prefs 里的 owner 标记一致；不满足一律不通知、不注册、不写通知状态。
//
// **主引擎前台身份对账**：[DormElectricityBackground.start] 仅由 `main` 在
// `runApp` 后安装统一认证监听，登出 / 换号 / 同号重登（revision 推进）时
// 经串行队列取消已排期的通用每日提醒（通知 id 200）与周期任务；后台
// isolate 不注册该监听、不发起自动登录。系统层重复闹钟的投递竞态窗口见
// [DormElectricityBackground.start] 的边界说明。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/notification/background_task_service.dart';
import 'dorm_electricity_service.dart';

const dormElectricityCheck = 'dormElectricityCheck';
const _scheduledNotificationId = 200;
const _immediateNotificationId = 100;
const _channelId = AppNotificationService.dormElectricityChannelId;
const _channelName = '寝室电费提醒';

// SharedPreferences keys（取自服务层公开常量，避免两处字面量漂移）。
const _keyAlertEnabled = DormElectricityService.keyAlertEnabled;
const _keyAlertThreshold = DormElectricityService.keyAlertThreshold;
const _keyLastNotifiedDate = DormElectricityService.keyAlertLastNotifiedDate;
const _keyCachedElectricity = DormElectricityService.keyElectricity;
const _keyCachedElectricityUpdatedAt =
    DormElectricityService.keyElectricityUpdatedAt;
const _keyAreaId = DormElectricityService.keyAreaId;
const _keyBuildingId = DormElectricityService.keyBuildingId;
const _keyFloorId = DormElectricityService.keyFloorId;
const _keyRoomId = DormElectricityService.keyRoomId;
const _keyRoomOwner = DormElectricityService.roomOwnerKey;
const _backgroundCacheMaxAge = Duration(hours: 24);

String _formatElectricity(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2);
}

/// 捕获的 owner + sessionRevision + prefs owner 标记是否仍一致。
bool _ownerStillCurrent({
  required String owner,
  required int revision,
  required SharedPreferences prefs,
}) {
  final auth = UnifiedAuthService.instance;
  return auth.verifiedAccount == owner &&
      auth.sessionRevision == revision &&
      prefs.getString(_keyRoomOwner) == owner;
}

/// 捕获的 owner/revision + owner 标记 + 预警开关是否仍一致。
///
/// 与 [_ownerStillCurrent] 的区别：额外要求预警仍开启——原生调度 / 注册在途
/// 期间用户关闭预警时同样必须回撤本次副作用。
bool _eligibilityStillCurrent({
  required String owner,
  required int revision,
  required SharedPreferences prefs,
}) {
  return _ownerStillCurrent(owner: owner, revision: revision, prefs: prefs) &&
      (prefs.getBool(_keyAlertEnabled) ?? false);
}

/// 读取「已配置房间 + 缓存未过期」的电量值；只读 prefs，绝不触网。
double? _readFreshConfiguredElectricity(SharedPreferences prefs) {
  if (prefs.getString(_keyAreaId) == null ||
      prefs.getString(_keyBuildingId) == null ||
      prefs.getString(_keyFloorId) == null ||
      prefs.getString(_keyRoomId) == null) {
    return null;
  }
  final updatedAtMillis = prefs.getInt(_keyCachedElectricityUpdatedAt);
  if (updatedAtMillis == null) return null;
  final age = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(updatedAtMillis),
  );
  if (age.isNegative || age > _backgroundCacheMaxAge) return null;
  return prefs.getDouble(_keyCachedElectricity);
}

Future<void> _showNotification({
  required int id,
  required double value,
  required double threshold,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  await plugin.show(
    id,
    '寝室电费不足',
    '剩余电量 ${_formatElectricity(value)} 度，低于 ${threshold.toInt()} 度阈值，请及时充值',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: '当寝室剩余电量低于设定阈值时发送提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
      ),
    ),
    payload: 'dorm-electricity',
  );
}

/// Schedule a daily notification for 8:00 AM.
/// Uses `setAlarmClock` when the user has granted exact-alarm access, otherwise
/// falls back to an inexact alarm — Android 12+ denies exact alarms by default
/// and a daily reminder does not need to-the-minute precision.
///
/// 边界：系统层重复闹钟一旦排队，投递前无法再复核房间 / 身份 / 缓存时效
/// （带具体电量的低电通知只由通过 owner 与 24 小时时效校验的即时检查
/// 发送）。主引擎前台由 [DormElectricityBackground.start] 的串行身份对账
/// 在登出 / 换号 / 同号重登时撤销本闹钟；WorkManager 后台 isolate 不承担
/// 该职责，且「身份变化 → 撤销」与系统实际投递之间仍存在有界竞态窗口，
/// 不得宣称该闹钟在登出后绝对账号安全。
Future<void> _scheduleDailyAlarmNotification() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
    if (!alertEnabled) return;

    // 只发通用提醒；文案在注册时固化，无法在每天投递前重新校验房间和缓存。
    const body = '每日电量检查 — 打开 App 查看最新电量';

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    final canScheduleExact =
        await plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.canScheduleExactNotifications() ??
        false;

    // Calculate next 8:00 AM.
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, 8);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    await plugin.zonedSchedule(
      _scheduledNotificationId,
      '寝室电费提醒',
      body,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '当寝室剩余电量低于设定阈值时发送提醒',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      androidScheduleMode: canScheduleExact
          ? AndroidScheduleMode.alarmClock
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: 'dorm-electricity',
      matchDateTimeComponents: DateTimeComponents.time,
    );

    AppLogger.instance.storage(LogLevel.debug, '已安排寝室电费每日提醒: $scheduled');
  } catch (e) {
    AppLogger.instance.storage(LogLevel.warn, '安排寝室电费每日提醒失败: $e');
  }
}

/// 后台检查 / 调度会产生的原生副作用（WorkManager 任务 + 本地通知）。
///
/// 单测注入替身即可验证「未注册 / 未取消 / 未通知」等 fail-closed 行为，
/// 不依赖平台通道。
abstract class DormBackgroundScheduler {
  Future<void> registerPeriodicTask();
  Future<void> cancelPeriodicTask();
  Future<void> scheduleDailyAlarm();
  Future<void> cancelDailyAlarm();
  Future<void> showLowElectricityNotification({
    required int id,
    required double value,
    required double threshold,
  });
}

class _PlatformDormBackgroundScheduler implements DormBackgroundScheduler {
  const _PlatformDormBackgroundScheduler();

  @override
  Future<void> registerPeriodicTask() =>
      BackgroundTaskService.instance.registerPeriodicTask(
        uniqueName: dormElectricityCheck,
        frequency: const Duration(hours: 8),
        initialDelay: const Duration(minutes: 15),
      );

  @override
  Future<void> cancelPeriodicTask() =>
      BackgroundTaskService.instance.cancelTask(dormElectricityCheck);

  @override
  Future<void> scheduleDailyAlarm() => _scheduleDailyAlarmNotification();

  @override
  Future<void> cancelDailyAlarm() async {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.cancel(_scheduledNotificationId);
  }

  @override
  Future<void> showLowElectricityNotification({
    required int id,
    required double value,
    required double threshold,
  }) => _showNotification(id: id, value: value, threshold: threshold);
}

/// 统一认证身份戳：已验证 owner + `sessionRevision`。
///
/// 只用于主引擎前台的身份对账去重：同一 `(owner, revision)` 的重复通知不再
/// 重复注册 / 取消；身份或 revision 变化必然产生新戳。owner 为 null 表示
/// 当前没有可信账号（登出 / 未恢复），同样需要去重。
@immutable
class _AuthIdentityStamp {
  const _AuthIdentityStamp({required this.owner, required this.revision});

  final String? owner;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is _AuthIdentityStamp &&
      other.owner == owner &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(owner, revision);
}

/// 主引擎内原生调度 / 取消副作用的 FIFO 串行队列（zone 安全）。
///
/// 语义与 `DormPrivateWrites` 的 drain 循环一致，**不可回退为
/// `Future.value()` 种子链**：
/// - 一次只执行一个动作；空闲后第一个动作决定本轮忙碌期的 zone，忙碌期内
///   入队的动作都在该 zone 执行，跨 zone 调用互不等待对方的 microtask；
/// - 不 `await` 别的 zone 创建的 Future；调用方等待的 `Completer` 始终在
///   调用方 zone 新建，完成时 SDK 会切回监听方 zone；
/// - 监听器路径不 await 队列返回的 Future，因此该路径的动作必须在内部
///   兜底异常（见 [_reconcileVerifiedOwner]）；显式路径（settings / 冷启动）
///   的错误照常通过返回的 Future 抛给调用方。
class _SerialEffectQueue {
  final List<_PendingEffect> _pending = <_PendingEffect>[];
  bool _draining = false;

  /// 基线重置代际：`debugReset` 使在途 drain 退出，旧用例的挂起动作绝不
  /// 消费新用例的队列。
  int _generation = 0;

  /// 当前忙碌期的 drain Future（空闲为 null）；测试可据此等待幂等收敛。
  Future<void>? _activeDrain;

  Future<void>? get activeDrain => _activeDrain;

  /// 把一次原生副作用动作排到队列尾部，返回其完成 Future。
  ///
  /// 队列自身永不因动作失败而断链：错误通过返回的 Future 抛给调用方，
  /// 后续动作不会被前一个失败动作卡住。
  Future<void> enqueue(Future<void> Function() action) {
    final completer = Completer<void>();
    _pending.add(_PendingEffect(action, completer));
    if (!_draining) {
      _draining = true;
      // 同步启动本轮 drain：它留在当前 zone 里，后续动作由它在本 zone 调用。
      final drain = _drain(_generation);
      _activeDrain = drain;
      unawaited(drain);
    }
    return completer.future;
  }

  Future<void> _drain(int generation) async {
    try {
      while (generation == _generation && _pending.isNotEmpty) {
        final entry = _pending.removeAt(0);
        try {
          await entry.action();
          entry.completer.complete();
        } catch (error, stackTrace) {
          entry.completer.completeError(error, stackTrace);
        }
      }
    } finally {
      if (generation == _generation) {
        _draining = false;
        _activeDrain = null;
      }
    }
  }

  /// 清空队列；推进代际让在途 drain 退出（不等待、不阻塞调用方）。
  void debugReset() {
    _generation++;
    _pending.clear();
    _draining = false;
    _activeDrain = null;
  }
}

class _PendingEffect {
  const _PendingEffect(this.action, this.completer);

  final Future<void> Function() action;
  final Completer<void> completer;
}

/// 寝室电费后台任务：低电量检查（前台/后台 isolate）与每日提醒调度。
class DormElectricityBackground {
  DormElectricityBackground._();
  static final instance = DormElectricityBackground._();

  /// 原生副作用入口；单测替换为替身。
  @visibleForTesting
  DormBackgroundScheduler scheduler = const _PlatformDormBackgroundScheduler();

  /// 测试注入：即时通知前的身份复核屏障（在最后一次 owner/revision 校验
  /// 之前执行），用于验证复核点前身份翻转必须 fail closed。
  @visibleForTesting
  Future<void> Function()? debugBeforeNotificationBarrier;

  /// 主引擎内原生调度 / 取消副作用的串行队列（zone 契约见 [_SerialEffectQueue]）。
  final _SerialEffectQueue _effects = _SerialEffectQueue();

  /// 最近一次对账完成时的身份戳；同一身份的重复通知不重复注册 / 取消。
  _AuthIdentityStamp? _lastAppliedIdentityStamp;

  /// 是否已安装统一认证身份监听（仅主引擎前台 [start] 安装）。
  bool _authListenerStarted = false;

  @visibleForTesting
  void debugReset() {
    // 身份监听必须随基线重置卸载：否则旧用例的监听器会跨用例污染
    // `UnifiedAuthService`（它在 debugReset 时不清监听器）。
    if (_authListenerStarted) {
      UnifiedAuthService.instance.removeListener(_onAuthChanged);
      _authListenerStarted = false;
    }
    _effects.debugReset();
    _lastAppliedIdentityStamp = null;
    scheduler = const _PlatformDormBackgroundScheduler();
    debugBeforeNotificationBarrier = null;
  }

  /// 仅主引擎前台启动：安装统一认证身份监听并立即排队一次对账（幂等）。
  ///
  /// `main` 在 `runApp` 之后、认证暖启动之前**同步**调用。
  /// `appBackgroundTaskDispatcher` / WorkManager 后台 isolate 绝不调用本
  /// 方法：后台不发起自动登录，也不承担身份变化的取消职责。
  ///
  /// 对账只使用**内存**统一认证身份（不 `restoreSession`）：
  /// - 登出 / 换号 / 同号重登（revision 推进）→ 立即经串行队列取消残留的
  ///   每日提醒（通知 id 200）与电费周期任务，不把 A 的通用提醒留给 B；
  /// - 新 owner 已验证、prefs owner 标记一致且预警开启 → 允许重新注册；
  /// - 冷启动的持久会话恢复仍由 [ensureScheduled] / 暖启动流程负责；这里
  ///   不读持久会话，避免与 `markLoggedOut` 的持久撤销竞态复活旧身份。
  ///
  /// 残留边界：系统层通知一旦投递无法撤回；「身份变化 → 串行取消」与系统
  /// 实际投递之间仍有有界竞态窗口，不得宣称绝对账号安全。
  void start() {
    if (_authListenerStarted) return;
    _authListenerStarted = true;
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    unawaited(onAuthIdentityChanged());
  }

  void _onAuthChanged() {
    unawaited(onAuthIdentityChanged());
  }

  /// 统一认证身份 / revision 变化触发的串行对账（测试可直接调用）。
  ///
  /// 返回本轮队列动作的完成 Future；生产监听器不等待（动作内部已兜底
  /// 异常）。对账在串行队列内执行，与 [ensureScheduled] / [reRegisterIfNeeded]
  /// / 前台重排绝不交错。
  Future<void> onAuthIdentityChanged() =>
      _effects.enqueue(_reconcileVerifiedOwner);

  /// 测试钩子：等待串行队列当前忙碌期（含忙碌期内并入的后续动作）结束。
  @visibleForTesting
  Future<void> debugWaitForIdle() async {
    while (true) {
      final drain = _effects.activeDrain;
      if (drain == null) return;
      await drain;
    }
  }

  /// 串行队列内的一次身份对账：按最新内存身份 + 磁盘 prefs 决定注册或取消。
  ///
  /// 同一身份戳重复触发直接返回（不重复注册 / 取消）。`prefs.reload()` 是
  /// 本方法最后一次 await；之后的资格判定与
  /// `scheduler.scheduleDailyAlarm()` 之间没有 await 窗口。每个 await 边界
  /// 之后都复核身份 / owner 标记 / 预警开关，翻转即在**同一动作内**回撤
  /// 本次可能已落地的陈旧副作用（见 [_revertStaleArtifacts]）。
  Future<void> _reconcileVerifiedOwner() async {
    try {
      final auth = UnifiedAuthService.instance;
      final prefs = await SharedPreferences.getInstance();
      // 后台 isolate 可能刚写过设置：按磁盘最新值判定。
      await prefs.reload();

      final owner = auth.verifiedAccount;
      final revision = auth.sessionRevision;
      final stamp = _AuthIdentityStamp(owner: owner, revision: revision);
      if (stamp == _lastAppliedIdentityStamp) return;

      final enabled = prefs.getBool(_keyAlertEnabled) ?? false;
      if (!enabled ||
          owner == null ||
          prefs.getString(_keyRoomOwner) != owner) {
        await _cancelScheduledArtifacts();
        _lastAppliedIdentityStamp = stamp;
        return;
      }

      await scheduler.scheduleDailyAlarm();
      if (!_eligibilityStillCurrent(
        owner: owner,
        revision: revision,
        prefs: prefs,
      )) {
        await _revertStaleArtifacts(prefs: prefs);
        return;
      }
      await scheduler.registerPeriodicTask();
      if (!_eligibilityStillCurrent(
        owner: owner,
        revision: revision,
        prefs: prefs,
      )) {
        await _revertStaleArtifacts(prefs: prefs);
        return;
      }
      _lastAppliedIdentityStamp = stamp;
    } catch (error) {
      AppLogger.instance.storage(LogLevel.warn, '寝室电费身份对账失败: $error');
    }
  }

  /// 原生副作用在途期间身份 / owner 标记 / 预警开关已翻转：在**同一串行
  /// 动作内**取消本次可能已落地的陈旧闹钟与周期任务，不依赖后续监听器通知
  /// （通知可能尚未排队或不存在）。
  ///
  /// 若取消后的最新身份本身不合格（未登录 / marker 不符 / 预警关闭），把它
  /// 记为「已对账」，让迟到的同身份监听器保持幂等；若最新身份合格（如快速
  /// 换号且 B 已就绪），不记戳，交给排队的监听器对账按 B 重新注册。
  Future<void> _revertStaleArtifacts({required SharedPreferences prefs}) async {
    await _cancelScheduledArtifacts();
    final auth = UnifiedAuthService.instance;
    final latestOwner = auth.verifiedAccount;
    final latestRevision = auth.sessionRevision;
    final latestEligible =
        latestOwner != null &&
        prefs.getString(_keyRoomOwner) == latestOwner &&
        (prefs.getBool(_keyAlertEnabled) ?? false);
    if (!latestEligible) {
      _lastAppliedIdentityStamp = _AuthIdentityStamp(
        owner: latestOwner,
        revision: latestRevision,
      );
    }
  }

  /// 串行队列内的显式状态应用：冷启动 / 设置切换必须按当前状态生效
  /// （开关切换后 prefs 已变化，不做「同身份戳跳过」去重）。
  ///
  /// **只用内存统一认证身份**：前台调度路径绝不 `restoreSession`——冷启动 /
  /// 登出持久撤销期间读旧 metadata 会复活旧身份并重排 A 的闹钟。未水合 /
  /// 未登录一律取消残留，真实登录通知经 [start] 的监听器对账重新注册。
  Future<void> _applyExplicitState() async {
    final prefs = await SharedPreferences.getInstance();
    final auth = UnifiedAuthService.instance;
    final owner = auth.verifiedAccount;
    final revision = auth.sessionRevision;
    final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
    if (!alertEnabled ||
        owner == null ||
        prefs.getString(_keyRoomOwner) != owner) {
      await _cancelScheduledArtifacts();
      _lastAppliedIdentityStamp = _AuthIdentityStamp(
        owner: owner,
        revision: revision,
      );
      return;
    }
    await scheduler.scheduleDailyAlarm();
    if (!_eligibilityStillCurrent(
      owner: owner,
      revision: revision,
      prefs: prefs,
    )) {
      await _revertStaleArtifacts(prefs: prefs);
      return;
    }
    await scheduler.registerPeriodicTask();
    if (!_eligibilityStillCurrent(
      owner: owner,
      revision: revision,
      prefs: prefs,
    )) {
      await _revertStaleArtifacts(prefs: prefs);
      return;
    }
    _lastAppliedIdentityStamp = _AuthIdentityStamp(
      owner: owner,
      revision: revision,
    );
  }

  /// 串行队列内的前台每日提醒重排：调度前按最新身份 + prefs 复核；身份失效
  /// / 预警关闭时静默跳过（取消由设置切换或身份对账负责）。调度在途期间身份
  /// / 开关翻转时在同一动作内回撤。
  Future<void> _rescheduleDailyAlarmIfCurrent() {
    return _effects.enqueue(() async {
      try {
        final auth = UnifiedAuthService.instance;
        final owner = auth.verifiedAccount;
        final revision = auth.sessionRevision;
        if (owner == null) return;
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        if (!_eligibilityStillCurrent(
          owner: owner,
          revision: revision,
          prefs: prefs,
        )) {
          return;
        }
        await scheduler.scheduleDailyAlarm();
        if (!_eligibilityStillCurrent(
          owner: owner,
          revision: revision,
          prefs: prefs,
        )) {
          await _revertStaleArtifacts(prefs: prefs);
        }
      } catch (error) {
        AppLogger.instance.storage(LogLevel.warn, '前台电费提醒重排失败: $error');
      }
    });
  }

  /// 当前 isolate 可用的已验证 owner（**仅后台检查路径使用**）。
  ///
  /// 未水合时只允许 [UnifiedAuthService.restoreSession]（`syncWebViewCookies:
  /// false`）恢复持久会话元数据：不触网、不发起自动登录、不碰 WebView；
  /// 恢复不出可信账号一律 fail closed。主引擎前台的调度 / 取消路径
  /// （[ensureScheduled] / [reRegisterIfNeeded] / 身份对账）不得使用本方法，
  /// 以免在登出持久撤销竞态中复活旧身份。
  ///
  /// **为何不经 `BackgroundSessionGate` 申领**（评审 #6 结论）：`restoreSession`
  /// 在 `syncWebViewCookies: false` 下只读安全存储里的会话元数据并改**本 isolate
  /// 自己的**内存身份——不触网、不读写 CookieJar、不推进或写入持久 epoch、不登录、
  /// 不碰 WebView；整个后台检查也只读 prefs 缓存（epay100 查询依赖前台 WebView）。
  /// 门保护的是「两个 isolate 同时写 Cookie / 会话」，这里没有可保护的写入；
  /// 反而若前台活跃就让位，会白白丢掉低电量提醒。身份是否仍可信由本文件已有的
  /// owner 标记 + sessionRevision + prefs.reload 多次复核（fail closed）负责。
  /// 日后若这里引入联网、Cookie 或自动登录，必须改走 `BackgroundAuthRun`。
  Future<String?> _resolveVerifiedOwner() async {
    final auth = UnifiedAuthService.instance;
    final current = auth.verifiedAccount;
    if (current != null) return current;
    try {
      await auth.restoreSession(syncWebViewCookies: false);
    } catch (error) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '电费后台任务恢复统一认证身份失败，按未登录处理',
        error: error,
      );
      return null;
    }
    return auth.verifiedAccount;
  }

  /// 后台检查入口，由 app 层 dispatcher 在 WorkManager isolate 中调用。
  ///
  /// epay100 查询依赖前台 WebView 会话，后台 isolate 只使用最近一次前台
  /// 刷新写入的缓存值判断低电量；owner / sessionRevision 在发起时捕获，
  /// 通知前与写通知状态前都重新复核（含 prefs.reload），不确定即放弃。
  Future<bool> executeBackgroundCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
      if (!alertEnabled) return true;

      final owner = await _resolveVerifiedOwner();
      if (owner == null) return true;
      final revision = UnifiedAuthService.instance.sessionRevision;
      if (prefs.getString(_keyRoomOwner) != owner) return true;

      await debugBeforeNotificationBarrier?.call();
      // 后台 isolate 的 prefs 镜像可能早于主 isolate 的写入：通知前重载并
      // 复核 owner / 账号 / sessionRevision / 预警开关，任何一项不确定都放弃。
      await prefs.reload();
      if (!_ownerStillCurrent(owner: owner, revision: revision, prefs: prefs)) {
        return true;
      }
      if (!(prefs.getBool(_keyAlertEnabled) ?? false)) return true;

      final threshold =
          prefs.getDouble(_keyAlertThreshold) ??
          DormElectricityService.defaultAlertThreshold;
      final lastNotified = prefs.getString(_keyLastNotifiedDate);
      final today = DormElectricityService.todayString();
      if (lastNotified == today) return true;

      final value = _readFreshConfiguredElectricity(prefs);
      if (value == null) return true;

      if (value < threshold) {
        await scheduler.showLowElectricityNotification(
          id: _immediateNotificationId,
          value: value,
          threshold: threshold,
        );
        // 通知已发出，但通知状态只允许写回仍然可信的 owner。
        await prefs.reload();
        if (!_ownerStillCurrent(
          owner: owner,
          revision: revision,
          prefs: prefs,
        )) {
          return true;
        }
        if (!(prefs.getBool(_keyAlertEnabled) ?? false)) return true;
        await prefs.setString(_keyLastNotifiedDate, today);
      } else {
        await prefs.remove(_keyLastNotifiedDate);
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  /// 注册寝室电费后台任务：每日 8:00 闹钟提醒（主）+ WorkManager
  /// 8 小时周期兜底检查（次）。
  ///
  /// 冷启动时预警关闭、owner 标记缺失或与可信账号不一致（含**内存身份未
  /// 水合**）一律**不注册**，并撤掉可能残留的旧任务/闹钟（已知审计缺陷：
  /// 旧实现会无条件重注册）。本路径只用内存统一认证身份，绝不
  /// `restoreSession`；真实登录通知由 [start] 的监听器对账重新注册。
  /// 与身份对账 / 设置切换共用同一条串行队列，原生副作用不交错。
  Future<void> ensureScheduled() => _effects.enqueue(_applyExplicitState);

  /// 用户切换电费预警设置后调用：启用且归属可信则重排，否则取消。
  /// 与身份对账 / 冷启动注册共用同一条串行队列。
  Future<void> reRegisterIfNeeded() => _effects.enqueue(_applyExplicitState);

  /// 逐个隔离取消；任一步失败只记日志，不影响另一项与调用方。
  Future<void> _cancelScheduledArtifacts() async {
    try {
      await scheduler.cancelDailyAlarm();
    } catch (error) {
      AppLogger.instance.storage(LogLevel.warn, '取消电费每日提醒失败: $error');
    }
    try {
      await scheduler.cancelPeriodicTask();
    } catch (error) {
      AppLogger.instance.storage(LogLevel.warn, '取消电费周期任务失败: $error');
    }
  }

  /// Foreground check — called on app resume. Refreshes electricity through
  /// the epay100 WebView-backed service, shows a low-value notification when
  /// needed, then reschedules the daily alarm with the latest cache.
  ///
  /// 与后台检查同一归属口径：未登录 / owner 不一致一律不通知、不写状态。
  Future<void> foregroundCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final owner = UnifiedAuthService.instance.verifiedAccount;
      if (owner == null) return;
      final revision = UnifiedAuthService.instance.sessionRevision;
      if (prefs.getString(_keyRoomOwner) != owner) return;

      final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
      if (!alertEnabled) return;

      final threshold =
          prefs.getDouble(_keyAlertThreshold) ??
          DormElectricityService.defaultAlertThreshold;
      final lastNotified = prefs.getString(_keyLastNotifiedDate);
      final today = DormElectricityService.todayString();

      // Resume checks should reuse the service's owner-scoped fresh cache. A
      // manual refresh remains the explicit path that bypasses this gate.
      final value = await DormElectricityService.instance.fetchElectricity();
      if (!_ownerStillCurrent(owner: owner, revision: revision, prefs: prefs)) {
        return;
      }
      if (value == null || DormElectricityService.instance.lastError != null) {
        return;
      }

      if (value < threshold && lastNotified != today) {
        await scheduler.showLowElectricityNotification(
          id: _immediateNotificationId,
          value: value,
          threshold: threshold,
        );
        if (!_ownerStillCurrent(
          owner: owner,
          revision: revision,
          prefs: prefs,
        )) {
          return;
        }
        await prefs.setString(_keyLastNotifiedDate, today);
      } else if (value >= threshold) {
        await prefs.remove(_keyLastNotifiedDate);
      }

      // 重排只含通用文案的每日提醒；具体电量不会固化进重复闹钟。经串行
      // 队列 + 最新身份复核，登出 / 换号后在途重排不会落在取消之后。
      await _rescheduleDailyAlarmIfCurrent();
    } catch (e) {
      AppLogger.instance.storage(LogLevel.warn, '前台电费检查失败: $e');
    }
  }
}
