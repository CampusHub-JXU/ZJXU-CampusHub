import 'campus_action_ids.dart';
import 'campus_action_registry.dart';

/// Deep Link 解析（PRD 0.7.0 §8）。
///
/// 新格式：`jxucampushub://action/<action-id>`
/// 旧格式：`jxucampushub://shortcut/<legacy-action>`（继续兼容一个大版本）
///
/// 外部链接禁止直接携带任意 URL / Route / Intent / Android Component；这里
/// 只接受注册表中的 action id，其余（含未知参数）一律拒绝。
class CampusDeepLink {
  CampusDeepLink._();

  static const scheme = 'jxucampushub';
  static const actionHost = 'action';
  static const legacyShortcutHost = 'shortcut';

  static const _legacyShortcutActions = <String, String>{
    'campus-card-payment': CampusActionIds.campusCardPayment,
    'shuati-practice': CampusActionIds.shuatiOpen,
  };

  /// 解析原始字符串；非本 scheme 或未注册返回 null。
  static String? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    return fromUri(uri);
  }

  static String? fromUri(Uri uri) {
    if (uri.scheme != scheme) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;

    switch (uri.host) {
      case actionHost:
        final id = segments.first;
        return CampusActionRegistry.instance.contains(id) ? id : null;
      case legacyShortcutHost:
        return _legacyShortcutActions[segments.first];
      default:
        return null;
    }
  }
}
