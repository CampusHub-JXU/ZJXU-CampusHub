/// 校园系统动作（CampusAction）。
///
/// Action ID 与 Route 解耦：feature / widget / shortcut / deep link 只引用稳定
/// 的 action id，启动方式（Route / WebView / WeChat / 浏览器 / 原生）由
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
  const RouteActionTarget(this.routeName);

  final String routeName;
}

class WebActionTarget extends CampusActionTarget {
  const WebActionTarget(this.url);

  final String url;
}

enum ProtectedWebAuth { unified, zhengfang }

class ProtectedWebActionTarget extends CampusActionTarget {
  const ProtectedWebActionTarget(
    this.url, {
    this.auth = ProtectedWebAuth.unified,
  });

  final String url;
  final ProtectedWebAuth auth;
}

class WechatActionTarget extends CampusActionTarget {
  const WechatActionTarget(this.url);

  final String url;
}

class ExternalActionTarget extends CampusActionTarget {
  const ExternalActionTarget(this.url);

  final String url;
}

class NativeActionTarget extends CampusActionTarget {
  const NativeActionTarget(this.handlerId);

  final String handlerId;
}

class CampusAction {
  const CampusAction({
    required this.id,
    required this.title,
    required this.target,
    this.subtitle,
  });

  final String id;
  final String title;
  final String? subtitle;
  final CampusActionTarget target;
}
