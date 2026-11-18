import 'package:flutter/foundation.dart';
import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';

import '../logging/app_logger.dart';
import 'android_platform_bindings.dart';

/// Android JNIgen 调用共用底座：统一处理平台守卫、Activity 获取、Arena 生命周期与异常降级。
class AndroidJniBridge {
  AndroidJniBridge._();

  /// 在当前 Flutter 引擎绑定的 Android [Activity] 上同步执行 [action]。
  ///
  /// - 非 Android / 无 `engineId` / 取不到 `Activity`：直接返回 [unavailable]。
  /// - 执行期间抛出异常：记录日志后返回 [failed]（若未传 [failed]，则回退 [unavailable]）。
  static T withActivity<T>(
    T Function(Arena arena, Activity activity) action, {
    required T unavailable,
    T? failed,
    required String label,
    LogCategory category = LogCategory.general,
  }) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return unavailable;
    }
    final engineId = PlatformDispatcher.instance.engineId;
    if (engineId == null) {
      return unavailable;
    }

    try {
      return using((arena) {
        final rawActivity = androidActivity(engineId);
        if (rawActivity == null) {
          return unavailable;
        }
        final activity = rawActivity.as(Activity.type, releaseOriginal: true)
          ..releasedBy(arena);
        return action(arena, activity);
      });
    } catch (error) {
      AppLogger.instance.log(LogLevel.warn, category, '$label失败: $error');
      return failed ?? unavailable;
    }
  }
}
