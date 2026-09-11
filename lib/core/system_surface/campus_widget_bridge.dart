import 'package:flutter/services.dart';

/// 桌面组件原生桥（PRD §13）。
///
/// 只接受「无凭据」的展示投影：`CampusSnapshot → WidgetProjection` 之后才进入
/// 这里，绝不传 Cookie / token / CAS 数据。方法在缺少原生实现时静默降级。
class CampusWidgetBridge {
  CampusWidgetBridge._();

  static final CampusWidgetBridge instance = CampusWidgetBridge._();

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/widget');

  /// 推送展示投影到原生组件状态。
  Future<void> pushSnapshot(Map<String, Object?> projection) async {
    try {
      await _channel.invokeMethod<void>('pushSnapshot', projection);
    } on MissingPluginException {
      // 无原生组件（旧设备/单元测试）：忽略。
    } on PlatformException {
      // 组件更新失败不影响 App 主流程。
    }
  }

  /// 请求添加桌面组件（固定）。返回是否成功发出请求。
  Future<bool> requestPin() async {
    try {
      return await _channel.invokeMethod<bool>('requestPin') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 设备/桌面是否支持固定组件。
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
