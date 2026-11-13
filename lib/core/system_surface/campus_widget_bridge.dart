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

/// 设置页展示用的桌面组件状态（契约见 `docs/desktop-widget-v2.md` §6）。
class CampusWidgetStatus {
  const CampusWidgetStatus({
    required this.pinSupported,
    required this.installed,
    this.lastSnapshotAt,
  });

  static const unknown = CampusWidgetStatus(pinSupported: false, installed: {});

  final bool pinSupported;

  /// 每种尺寸已放置的实例数；缺失的尺寸按 0。
  final Map<CampusWidgetSize, int> installed;

  /// 原生最近一次收到快照的时间；从未收到为 null。
  final DateTime? lastSnapshotAt;

  int installedCount(CampusWidgetSize size) => installed[size] ?? 0;

  /// 解析 widget 通道 `getStatus` 的返回；字段缺失 / 类型不符按 0 / null 兜底。
  static CampusWidgetStatus fromPlatformValue(Object? value) {
    if (value is! Map) return unknown;
    final rawInstalled = value['installed'];
    final installed = <CampusWidgetSize, int>{};
    if (rawInstalled is Map) {
      for (final size in CampusWidgetSize.values) {
        final count = rawInstalled[size.code];
        if (count is int && count > 0) installed[size] = count;
      }
    }
    final lastMs = value['lastSnapshotAtMs'];
    return CampusWidgetStatus(
      pinSupported: value['pinSupported'] == true,
      installed: installed,
      lastSnapshotAt: lastMs is int && lastMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(lastMs)
          : null,
    );
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

  /// 后台引擎可用的已放置组件实例数（三种尺寸合计）；插件缺失或查询失败返回
  /// null（未知），调用方不得把未知当成「没放」。
  Future<int?> backgroundInstalledCount() => safeInvoke<int?, int?>(
    const MethodChannel('edu.zjxu.jxucampushub/widget_store'),
    'installedCount',
    map: (v) => v is int ? v : null,
    missing: null,
    failed: null,
    label: '后台组件实例数查询',
  );

  /// 后台引擎使用自动注册插件，返回真实落盘结果；失败不得记成功。
  Future<bool> pushBackgroundSnapshot(Map<String, Object?> projection) =>
      safeInvoke<bool, bool>(
        const MethodChannel('edu.zjxu.jxucampushub/widget_store'),
        'push',
        arguments: {'snapshot': projection},
        map: (v) => v == true,
        missing: false,
        failed: false,
        label: '后台组件快照推送',
      );

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

  /// 读取已放置实例数与最近同步时间；通道缺失 / 失败返回 [CampusWidgetStatus.unknown]。
  Future<CampusWidgetStatus> getStatus() =>
      safeInvoke<Object, CampusWidgetStatus>(
        _channel,
        'getStatus',
        map: CampusWidgetStatus.fromPlatformValue,
        missing: CampusWidgetStatus.unknown,
        failed: CampusWidgetStatus.unknown,
        label: '读取桌面组件状态',
        level: LogLevel.warn,
        category: LogCategory.general,
      );

  /// 原生把 launcher 组件选择器同款的 `previewLayout` 渲染成 PNG 位图
  /// （设置页「桌面与后台」预览用）。[widthPx] 为位图的目标展示宽（物理像素），
  /// 字号按真实 sp 栅格化不缩放失真；通道缺失 / 失败返回 null，UI 隐藏预览。
  Future<Uint8List?> getPreview(CampusWidgetSize size, {required int widthPx}) =>
      safeInvoke<Uint8List, Uint8List?>(
        _channel,
        'getPreview',
        arguments: <String, Object?>{'size': size.code, 'widthPx': widthPx},
        map: (value) => value,
        missing: null,
        failed: null,
        label: '读取桌面组件预览',
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
