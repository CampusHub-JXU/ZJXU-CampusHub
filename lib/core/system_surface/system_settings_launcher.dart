import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';

import '../logging/app_logger.dart';
import '../platform/android_platform_bindings.dart';
import '../platform/safe_invoke.dart';

/// 系统设置页跳转目标（固定契约，设置页 / 权限引导共用）。
enum SystemSettingsTarget {
  /// 应用通知设置（Android 8.0+）。
  notifications,

  /// 单个通知渠道设置页（Android 8.0+，需在 [SystemSettingsLauncher.open] 里传
  /// [SystemSettingsLauncher.channelId]）。渠道不存在 / 系统不支持时按降级链处理。
  notificationChannel,

  /// 应用详情页（权限总入口）。
  appDetails,

  /// 精确闹钟设置（Android 12+；低版本降级到应用详情页）。
  exactAlarms,

  /// 电池优化列表页（只打开列表，不发起直接授权弹窗）。
  batteryOptimization,

  /// 自启动管理（仅小米 ROM 尽力尝试，无官方保证）。
  autostart,
}

/// 实际打开的系统设置页。
///
/// 原生侧逐级降级，因此返回值可能与请求的 [SystemSettingsTarget] 不同：
/// [target] 表示命中目标页，[appDetails] / [settings] 表示降级到了应用详情页 /
/// 系统设置首页，[unavailable] 表示全部失败或通道缺失。
enum SystemSettingsOpenResult { target, appDetails, settings, unavailable }

/// 后台运行相关的真实系统状态（契约见 `docs/desktop-widget-v2.md` §6）。
///
/// [available] 为 false 表示整体查询失败（通道缺失 / 原生异常），此时各项都是未知；
/// [available] 为 true 时单项 null 表示该项不适用（如 Android 12 以下的精确闹钟）
/// 或单独读取失败。**只读**，不代表也不改变任何授权。
class SystemBackgroundStatus {
  const SystemBackgroundStatus({
    this.available = true,
    this.notificationsEnabled,
    this.exactAlarmsAllowed,
    this.ignoringBatteryOptimizations,
    this.isXiaomiFamily = false,
  });

  static const unknown = SystemBackgroundStatus(available: false);

  final bool available;

  final bool? notificationsEnabled;
  final bool? exactAlarmsAllowed;
  final bool? ignoringBatteryOptimizations;
  final bool isXiaomiFamily;

  /// 解析 system_settings 通道 `getStatus` 的返回；非 Map 视为整体未知。
  static SystemBackgroundStatus fromPlatformValue(Object? value) {
    if (value is! Map) return unknown;
    bool? flag(String key) {
      final v = value[key];
      return v is bool ? v : null;
    }

    return SystemBackgroundStatus(
      notificationsEnabled: flag('notificationsEnabled'),
      exactAlarmsAllowed: flag('exactAlarmsAllowed'),
      ignoringBatteryOptimizations: flag('ignoringBatteryOptimizations'),
      isXiaomiFamily: value['isXiaomiFamily'] == true,
    );
  }
}

/// 系统设置 launcher（方法通道 `edu.zjxu.jxucampushub/system_settings`）。
///
/// 只负责把用户带到对应设置页：**打开成功不代表权限已授予**，调用方不得据此
/// 改写权限状态；本类不修改任何权限，也不申请危险权限。
///
/// 非 Android / 测试环境下通道缺失（`MissingPluginException`）或原生异常
/// （`PlatformException`）一律降级为 [SystemSettingsOpenResult.unavailable]，
/// 不向 UI 抛出平台异常。
class SystemSettingsLauncher {
  SystemSettingsLauncher._();

  static final SystemSettingsLauncher instance = SystemSettingsLauncher._();

  static const _channel = MethodChannel(
    'edu.zjxu.jxucampushub/system_settings',
  );

  /// 打开 [target] 对应的系统设置页。
  ///
  /// [channelId] 仅在 [SystemSettingsTarget.notificationChannel] 时有意义，为要打开
  /// 的通知渠道 ID（如 `AppNotificationService.secondClassroomChannelId`）；漏传时
  /// 原生按降级链退回应用详情页，不伪造渠道页。
  Future<SystemSettingsOpenResult> open(
    SystemSettingsTarget target, {
    String? channelId,
  }) async {
    final normalizedChannelId = channelId?.trim();
    final effectiveChannelId =
        (normalizedChannelId != null && normalizedChannelId.isNotEmpty)
        ? normalizedChannelId
        : null;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final jniResult = _openViaJni(target, effectiveChannelId);
      if (jniResult != null) return jniResult;
    }

    return safeInvoke<String, SystemSettingsOpenResult>(
      _channel,
      'open',
      arguments: <String, Object?>{
        'target': target.name,
        'channelId': ?effectiveChannelId,
      },
      map: _fromPlatformValue,
      missing: SystemSettingsOpenResult.unavailable,
      failed: SystemSettingsOpenResult.unavailable,
      label: '打开系统设置页（${target.name}）',
      level: LogLevel.warn,
      category: LogCategory.general,
    );
  }

  /// 查询后台运行相关的真实状态；通道缺失 / 失败返回 [SystemBackgroundStatus.unknown]。
  Future<SystemBackgroundStatus> getStatus() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final jniStatus = _getStatusViaJni();
      if (jniStatus != null) return jniStatus;
    }

    return safeInvoke<Object, SystemBackgroundStatus>(
      _channel,
      'getStatus',
      map: SystemBackgroundStatus.fromPlatformValue,
      missing: SystemBackgroundStatus.unknown,
      failed: SystemBackgroundStatus.unknown,
      label: '读取后台运行状态',
      level: LogLevel.warn,
      category: LogCategory.general,
    );
  }

  SystemSettingsOpenResult? _openViaJni(
    SystemSettingsTarget target,
    String? channelId,
  ) {
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) return null;
    try {
      return using((arena) {
        final rawActivity = androidActivity(engineId);
        if (rawActivity == null) return null;
        final activity = rawActivity.as(Activity.type, releaseOriginal: true)
          ..releasedBy(arena);
        final handler = SystemSettingsChannelHandler(activity)
          ..releasedBy(arena);
        final jTarget = target.name.toJString()..releasedBy(arena);
        final jChannelId = channelId == null
            ? null
            : (channelId.toJString()..releasedBy(arena));
        final result = handler.open(jTarget, jChannelId)..releasedBy(arena);
        return _fromPlatformValue(result.toDartString());
      });
    } catch (error) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        'JNI 调用打开系统设置页失败（${target.name}）: $error',
      );
      return SystemSettingsOpenResult.unavailable;
    }
  }

  SystemBackgroundStatus? _getStatusViaJni() {
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) return null;
    try {
      return using((arena) {
        final rawActivity = androidActivity(engineId);
        if (rawActivity == null) return null;
        final activity = rawActivity.as(Activity.type, releaseOriginal: true)
          ..releasedBy(arena);
        final handler = SystemSettingsChannelHandler(activity)
          ..releasedBy(arena);
        final snapshot = handler.readStatusSnapshot()..releasedBy(arena);
        final notifications = snapshot.notificationsEnabled;
        final exactAlarms = snapshot.exactAlarmsAllowed;
        final batteryOpt = snapshot.ignoringBatteryOptimizations;
        if (notifications != null) notifications.releasedBy(arena);
        if (exactAlarms != null) exactAlarms.releasedBy(arena);
        if (batteryOpt != null) batteryOpt.releasedBy(arena);
        return SystemBackgroundStatus(
          notificationsEnabled: notifications?.booleanValue(),
          exactAlarmsAllowed: exactAlarms?.booleanValue(),
          ignoringBatteryOptimizations: batteryOpt?.booleanValue(),
          isXiaomiFamily: snapshot.isXiaomiFamily,
        );
      });
    } catch (error) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        'JNI 读取后台运行状态失败: $error',
      );
      return SystemBackgroundStatus.unknown;
    }
  }

  static SystemSettingsOpenResult _fromPlatformValue(String? value) {
    return switch (value) {
      'target' => SystemSettingsOpenResult.target,
      'appDetails' => SystemSettingsOpenResult.appDetails,
      'settings' => SystemSettingsOpenResult.settings,
      _ => SystemSettingsOpenResult.unavailable,
    };
  }
}
