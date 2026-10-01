import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../platform/safe_invoke.dart';

/// 桌面组件原生桥（PRD §13）。
///
/// 只接受「无凭据」的展示投影：`CampusSnapshot → WidgetProjection` 之后才进入
/// 这里，绝不传 Cookie / token / CAS 数据。方法在缺少原生实现时静默降级。
class CampusWidgetBridge {
  CampusWidgetBridge._();

  static final CampusWidgetBridge instance = CampusWidgetBridge._();

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/widget');

  /// 推送展示投影到原生桌面组件状态。
  ///
  /// 原生侧读取的是 `snapshot` 参数（`call.argument("snapshot")`），因此这里必须
  /// 包装成 `{'snapshot': {...}}`；直接传投影 map 会让原生拿不到数据并抛
  /// `invalid_args`（此前的静默失败即由此产生）。
  Future<void> pushSnapshot(Map<String, Object?> projection) {
    // 原生组件不可用（旧设备/单元测试）静默降级；推送失败不影响 App 主流程，
    // 但要留下可诊断的记录。非平台异常仍原样抛出（保持原语义）。
    return safeInvoke<void, void>(
      _channel,
      'pushSnapshot',
      arguments: <String, Object?>{'snapshot': projection},
      map: (_) {},
      missing: null,
      failed: null,
      label: '桌面组件投影推送',
      level: LogLevel.warn,
      category: LogCategory.general,
      catchUnknown: false,
    );
  }

  /// 请求添加桌面组件（固定）。返回是否成功发出请求。
  Future<bool> requestPin() => _invokeBool('requestPin');

  /// 设备/桌面是否支持固定组件。
  Future<bool> isSupported() => _invokeBool('isSupported');

  Future<bool> _invokeBool(String method) => safeInvoke<bool, bool>(
    _channel,
    method,
    map: (value) => value ?? false,
    missing: false,
    failed: false,
    catchUnknown: false,
  );
}
