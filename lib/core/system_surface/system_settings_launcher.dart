import 'package:flutter/foundation.dart';
import 'package:jni/jni.dart';

import '../logging/app_logger.dart';
import '../platform/android_jni_bridge.dart';
import '../platform/android_platform_bindings.dart';

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
}

/// 系统设置原生能力网关（默认通过 JNIgen 直调 Kotlin，单测可注入 Fake）。
abstract interface class SystemSettingsGateway {
  Future<SystemSettingsOpenResult> open(
    SystemSettingsTarget target, {
    String? channelId,
  });

  Future<SystemBackgroundStatus> getStatus();
}

class _JniSystemSettingsGateway implements SystemSettingsGateway {
  const _JniSystemSettingsGateway();

  @override
  Future<SystemSettingsOpenResult> open(
    SystemSettingsTarget target, {
    String? channelId,
  }) async {
    return AndroidJniBridge.withActivity<SystemSettingsOpenResult>(
      (arena, activity) {
        final handler = SystemSettingsChannelHandler(activity)
          ..releasedBy(arena);
        final jTarget = target.name.toJString()..releasedBy(arena);
        final jChannelId = channelId == null
            ? null
            : (channelId.toJString()..releasedBy(arena));
        final result = handler.open(jTarget, jChannelId)..releasedBy(arena);
        return SystemSettingsLauncher.parseOpenResult(result.toDartString());
      },
      unavailable: SystemSettingsOpenResult.unavailable,
      label: 'JNI 调用打开系统设置页（${target.name}）',
      category: LogCategory.general,
    );
  }

  @override
  Future<SystemBackgroundStatus> getStatus() async {
    return AndroidJniBridge.withActivity<SystemBackgroundStatus>(
      (arena, activity) {
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
      },
      unavailable: SystemBackgroundStatus.unknown,
      label: 'JNI 读取后台运行状态',
      category: LogCategory.general,
    );
  }
}

/// 系统设置 launcher（Android 经 JNIgen 直调 `SystemSettingsChannelHandler`）。
///
/// 只负责把用户带到对应设置页：**打开成功不代表权限已授予**，调用方不得据此
/// 改写权限状态；本类不修改任何权限，也不申请危险权限。
///
/// 非 Android / 测试环境或原生异常一律降级为 [SystemSettingsOpenResult.unavailable]，
/// 不向 UI 抛出平台异常。
class SystemSettingsLauncher {
  SystemSettingsLauncher._();

  static final SystemSettingsLauncher instance = SystemSettingsLauncher._();

  SystemSettingsGateway _gateway = const _JniSystemSettingsGateway();

  @visibleForTesting
  void setGatewayForTesting(SystemSettingsGateway? gateway) {
    _gateway = gateway ?? const _JniSystemSettingsGateway();
  }

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

    return _gateway.open(target, channelId: effectiveChannelId);
  }

  /// 查询后台运行相关的真实状态；非 Android / 失败返回 [SystemBackgroundStatus.unknown]。
  Future<SystemBackgroundStatus> getStatus() => _gateway.getStatus();

  @visibleForTesting
  static SystemSettingsOpenResult parseOpenResult(String? value) {
    return switch (value) {
      'target' => SystemSettingsOpenResult.target,
      'appDetails' => SystemSettingsOpenResult.appDetails,
      'settings' => SystemSettingsOpenResult.settings,
      _ => SystemSettingsOpenResult.unavailable,
    };
  }
}
