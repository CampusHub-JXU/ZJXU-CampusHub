/// 校园系统动作（CampusAction）。
///
/// Action ID 与 Route 解耦：feature / widget / shortcut / deep link 只引用稳定
/// 的 action id，启动方式（Route / WeChat；WebView 经 `external-webview` 路由）由
/// [CampusActionRegistry] 决定、由 [CampusActionExecutor] 执行。
///
/// 分层说明：本层放在 core 而非 app，因为 feature 需要同时“产生”和“分发”动作，
/// 而 feature 不得依赖 app（见 test/structure/import_layering_test.dart）。
library;

/// 动作执行结果，对应 PRD 0.7.0 §6。
enum CampusActionStatus {
  success,
  unsupported,
  targetUnavailable,
  permissionRequired,
  fallbackAvailable,
  failed,
}

class CampusActionResult {
  const CampusActionResult(this.status, {this.message});

  final CampusActionStatus status;
  final String? message;

  bool get isSuccess => status == CampusActionStatus.success;
}

/// 动作的启动目标（sealed，便于执行器穷尽分支）。
sealed class CampusActionTarget {
  const CampusActionTarget();
}

class RouteActionTarget extends CampusActionTarget {
  const RouteActionTarget(this.routeName, {this.extra});

  final String routeName;

  /// 随路由传递的参数（如受信教务 H5 入口标记）。
  final Map<String, Object?>? extra;
}

class WechatActionTarget extends CampusActionTarget {
  const WechatActionTarget(this.url);

  final String url;
}

class CampusAction {
  const CampusAction({
    required this.id,
    required this.title,
    required this.target,
  });

  final String id;
  final String title;
  final CampusActionTarget target;
}
