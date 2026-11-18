import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:jni/jni.dart';

import '../logging/app_logger.dart';
import '../platform/android_jni_bridge.dart';
import '../platform/android_platform_bindings.dart';
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

/// 桌面组件前台原生能力网关（默认通过 JNIgen 直调 Kotlin，单测可注入 Fake）。
abstract interface class CampusWidgetGateway {
  Future<void> pushSnapshot(Map<String, Object?> projection);

  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size);

  Future<CampusWidgetStatus> getStatus();

  Future<Uint8List?> getPreview(CampusWidgetSize size, {required int widthPx});

  Future<bool> isSupported();
}

class _JniCampusWidgetGateway implements CampusWidgetGateway {
  const _JniCampusWidgetGateway();

  @override
  Future<void> pushSnapshot(Map<String, Object?> projection) async {
    final snapshotJson = jsonEncode(projection);
    AndroidJniBridge.withActivity<void>(
      (arena, activity) {
        final handler = WidgetChannelHandler(activity)..releasedBy(arena);
        final jJson = snapshotJson.toJString()..releasedBy(arena);
        handler.pushSnapshot(jJson);
      },
      unavailable: null,
      label: 'JNI 桌面组件投影推送',
      category: LogCategory.general,
    );
  }

  @override
  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size) async {
    return AndroidJniBridge.withActivity<CampusWidgetPinResult>(
      (arena, activity) {
        final handler = WidgetChannelHandler(activity)..releasedBy(arena);
        final jSize = size.code.toJString()..releasedBy(arena);
        final code = (handler.requestPin(
          jSize,
        )..releasedBy(arena)).toDartString();
        return CampusWidgetPinResult.fromPlatformValue(code);
      },
      unavailable: CampusWidgetPinResult.unsupported,
      failed: CampusWidgetPinResult.error,
      label: 'JNI 添加桌面组件',
      category: LogCategory.general,
    );
  }

  @override
  Future<CampusWidgetStatus> getStatus() async {
    return AndroidJniBridge.withActivity<CampusWidgetStatus>(
      (arena, activity) {
        final handler = WidgetChannelHandler(activity)..releasedBy(arena);
        final snapshot = handler.readStatusSnapshot()..releasedBy(arena);
        final installed = <CampusWidgetSize, int>{
          if (snapshot.smallCount > 0)
            CampusWidgetSize.small: snapshot.smallCount,
          if (snapshot.mediumCount > 0)
            CampusWidgetSize.medium: snapshot.mediumCount,
          if (snapshot.largeCount > 0)
            CampusWidgetSize.large: snapshot.largeCount,
        };
        final lastMs = snapshot.lastSnapshotAtMs;
        return CampusWidgetStatus(
          pinSupported: snapshot.pinSupported,
          installed: installed,
          lastSnapshotAt: lastMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(lastMs)
              : null,
        );
      },
      unavailable: CampusWidgetStatus.unknown,
      label: 'JNI 读取桌面组件状态',
      category: LogCategory.general,
    );
  }

  @override
  Future<Uint8List?> getPreview(
    CampusWidgetSize size, {
    required int widthPx,
  }) async {
    return AndroidJniBridge.withActivity<Uint8List?>(
      (arena, activity) {
        final handler = WidgetChannelHandler(activity)..releasedBy(arena);
        final jSize = size.code.toJString()..releasedBy(arena);
        final jBytes = handler.getPreview(jSize, widthPx);
        if (jBytes == null) return null;
        jBytes.releasedBy(arena);
        final signed = jBytes.getRange(0, jBytes.length);
        return signed.buffer.asUint8List(
          signed.offsetInBytes,
          signed.lengthInBytes,
        );
      },
      unavailable: null,
      label: 'JNI 读取桌面组件预览',
      category: LogCategory.general,
    );
  }

  @override
  Future<bool> isSupported() async {
    return AndroidJniBridge.withActivity<bool>(
      (arena, activity) {
        final handler = WidgetChannelHandler(activity)..releasedBy(arena);
        return handler.isSupported;
      },
      unavailable: false,
      label: 'JNI 检查桌面组件固定支持',
      category: LogCategory.general,
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

  CampusWidgetGateway _gateway = const _JniCampusWidgetGateway();

  @visibleForTesting
  void setGatewayForTesting(CampusWidgetGateway? gateway) {
    _gateway = gateway ?? const _JniCampusWidgetGateway();
  }

  /// 推送展示投影到原生桌面组件状态（前台走 JNIgen 直调）。
  Future<void> pushSnapshot(Map<String, Object?> projection) =>
      _gateway.pushSnapshot(projection);

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
  /// 非 Android / 不支持 → [CampusWidgetPinResult.unsupported]；
  /// 原生异常与未知返回值 → [CampusWidgetPinResult.error]，不向 UI 抛异常。
  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size) =>
      _gateway.requestPin(size);

  /// 读取已放置实例数与最近同步时间；非 Android / 失败返回 [CampusWidgetStatus.unknown]。
  Future<CampusWidgetStatus> getStatus() => _gateway.getStatus();

  /// 原生把 launcher 组件选择器同款的 `previewLayout` 渲染成 PNG 位图
  /// （设置页「桌面与后台」预览用）。[widthPx] 为位图的目标展示宽（物理像素），
  /// 字号按真实 sp 栅格化不缩放失真；非 Android / 失败返回 null，UI 隐藏预览。
  Future<Uint8List?> getPreview(
    CampusWidgetSize size, {
    required int widthPx,
  }) => _gateway.getPreview(size, widthPx: widthPx);

  /// 设备/桌面是否支持固定组件。
  Future<bool> isSupported() => _gateway.isSupported();
}
