import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../platform/safe_invoke.dart';

/// 桌面组件的三种固定尺寸（与原生 `CampusWidgetKind` 一一对应）。
enum CampusWidgetSize {
  /// 2×2「下一节课」。
  small('small', '小 · 2×2', '下一节课'),

  /// 4×2「今日课表」。
  medium('medium', '中 · 4×2', '今日课表'),

  /// 4×4「校园总览」。
  large('large', '大 · 4×4', '校园总览');

  const CampusWidgetSize(this.code, this.sizeLabel, this.contentLabel);

  /// 通道参数 `size` 的取值。
  final String code;

  /// 例如「小 · 2×2」。
  final String sizeLabel;

  /// 该尺寸展示的内容，例如「下一节课」。
  final String contentLabel;
}

/// 固定桌面组件请求的结果。
///
/// [requested] 只表示请求已交给桌面（launcher），组件落在哪一页 / 哪个格子由
/// launcher 决定，App 无法控制，也不代表用户已确认。
enum CampusWidgetPinResult {
  requested,

  /// 系统 / 桌面不支持固定组件（含通道缺失）。
  unsupported,

  /// 被拒绝：MIUI/HyperOS「桌面快捷方式」权限被关，或桌面拒绝了请求。
  rejected,

  /// 原生异常（含 PlatformException）。
  error;

  static CampusWidgetPinResult fromPlatformValue(Object? value) {
    return switch (value) {
      'requested' => CampusWidgetPinResult.requested,
      'unsupported' => CampusWidgetPinResult.unsupported,
      'rejected' => CampusWidgetPinResult.rejected,
      _ => CampusWidgetPinResult.error,
    };
  }
}

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

  /// 请求把指定尺寸的组件固定到桌面。
  ///
  /// 通道缺失（非 Android / 单测）→ [CampusWidgetPinResult.unsupported]；
  /// [PlatformException]、未知异常与未知返回值 → [CampusWidgetPinResult.error]，不向 UI 抛异常。
  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size) =>
      safeInvoke<Object, CampusWidgetPinResult>(
        _channel,
        'requestPin',
        arguments: <String, Object?>{'size': size.code},
        map: CampusWidgetPinResult.fromPlatformValue,
        missing: CampusWidgetPinResult.unsupported,
        failed: CampusWidgetPinResult.error,
        label: '添加桌面组件',
        level: LogLevel.warn,
        category: LogCategory.general,
      );

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
