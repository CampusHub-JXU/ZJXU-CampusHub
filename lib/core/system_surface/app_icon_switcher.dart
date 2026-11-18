import 'package:flutter/foundation.dart';
import 'package:jni/jni.dart';

import '../logging/app_logger.dart';
import '../platform/android_jni_bridge.dart';
import '../platform/android_platform_bindings.dart';

/// 桌面图标切换原生能力网关（默认通过 JNIgen 直调 Kotlin，单测可注入 Fake）。
abstract interface class AppIconGateway {
  Future<bool> setAlias(String alias);

  Future<String?> getCurrentAlias();
}

class _JniAppIconGateway implements AppIconGateway {
  const _JniAppIconGateway();

  @override
  Future<bool> setAlias(String alias) async {
    return AndroidJniBridge.withActivity<bool>(
      (arena, activity) {
        final handler = AppIconChannelHandler(activity)..releasedBy(arena);
        final jAlias = alias.toJString()..releasedBy(arena);
        return handler.setIconAlias(jAlias);
      },
      unavailable: false,
      label: 'JNI 切换桌面图标',
      category: LogCategory.ui,
    );
  }

  @override
  Future<String?> getCurrentAlias() async {
    return AndroidJniBridge.withActivity<String?>(
      (arena, activity) {
        final handler = AppIconChannelHandler(activity)..releasedBy(arena);
        final jAlias = handler.iconAlias..releasedBy(arena);
        return jAlias.toDartString();
      },
      unavailable: null,
      label: 'JNI 读取当前桌面图标',
      category: LogCategory.ui,
    );
  }
}

/// 切换 Android 桌面 `<activity-alias>` 图标的原生桥接封装（Android 经 JNIgen 直调）。
class AppIconSwitcher {
  AppIconSwitcher._();

  static final AppIconSwitcher instance = AppIconSwitcher._();

  AppIconGateway _gateway = const _JniAppIconGateway();
  String? _lastRequestedAlias;

  @visibleForTesting
  Future<bool> Function(String alias)? debugOverrideSetAlias;

  @visibleForTesting
  void setGatewayForTesting(AppIconGateway? gateway) {
    _gateway = gateway ?? const _JniAppIconGateway();
  }

  Future<bool> setAlias(String alias) async {
    if (alias.isEmpty) return false;
    if (_lastRequestedAlias == alias) return true;
    _lastRequestedAlias = alias;

    final override = debugOverrideSetAlias;
    if (override != null) {
      return override(alias);
    }

    return _gateway.setAlias(alias);
  }

  Future<String?> getCurrentAlias() => _gateway.getCurrentAlias();

  void clearCache() {
    _lastRequestedAlias = null;
  }

  @visibleForTesting
  void debugReset() {
    _lastRequestedAlias = null;
    debugOverrideSetAlias = null;
    _gateway = const _JniAppIconGateway();
  }
}
