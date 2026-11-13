import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../platform/safe_invoke.dart';

/// 切换 Android 桌面 `<activity-alias>` 图标的平台通道封装。
class AppIconSwitcher {
  AppIconSwitcher._();

  static final AppIconSwitcher instance = AppIconSwitcher._();

  static const MethodChannel _channel = MethodChannel(
    'edu.zjxu.jxucampushub/app_icon',
  );

  String? _lastRequestedAlias;

  @visibleForTesting
  Future<bool> Function(String alias)? debugOverrideSetAlias;

  Future<bool> setAlias(String alias) async {
    if (alias.isEmpty) return false;
    if (_lastRequestedAlias == alias) return true;
    _lastRequestedAlias = alias;

    final override = debugOverrideSetAlias;
    if (override != null) {
      return override(alias);
    }

    return safeInvoke<bool, bool>(
      _channel,
      'setIconAlias',
      arguments: <String, Object>{'alias': alias},
      map: (value) => value ?? false,
      missing: false,
      failed: false,
      label: '切换桌面图标',
      category: LogCategory.ui,
      level: LogLevel.warn,
    );
  }

  Future<String?> getCurrentAlias() {
    return safeInvoke<String, String?>(
      _channel,
      'getIconAlias',
      map: (value) => value,
      missing: null,
      failed: null,
      label: '读取当前桌面图标',
      category: LogCategory.ui,
      level: LogLevel.warn,
    );
  }

  void clearCache() {
    _lastRequestedAlias = null;
  }

  @visibleForTesting
  void debugReset() {
    _lastRequestedAlias = null;
    debugOverrideSetAlias = null;
  }
}
