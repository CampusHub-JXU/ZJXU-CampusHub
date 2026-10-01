import 'package:flutter/foundation.dart';

import '../core/actions/campus_action.dart';
import '../core/actions/campus_action_executor.dart';
import '../core/actions/campus_action_registry.dart';
import 'app_messenger.dart';
import 'routes.dart';

/// 无 UI 上下文的 Action 分发入口（深链 / 快捷方式）。
///
/// Route 目标直接走 [appRouter]（不需要 BuildContext）；WeChat / Web / 外部
/// 目标交给 [CampusActionExecutor]，用全局 messenger 的 context 显示反馈。
class AppActionDispatcher {
  AppActionDispatcher._();

  /// 路由跳转实现；测试可替换以断言 routeName / extra 是否被完整透传。
  @visibleForTesting
  static Future<void> Function(String routeName, {Object? extra}) pushRoute =
      _pushOnAppRouter;

  static Future<void> _pushOnAppRouter(String routeName, {Object? extra}) {
    return appRouter.pushNamed(routeName, extra: extra);
  }

  static Future<void> dispatch(String actionId) async {
    final action = CampusActionRegistry.instance.findById(actionId);
    if (action == null) return;

    final target = action.target;
    if (target is RouteActionTarget) {
      await pushRoute(target.routeName, extra: target.extra);
      return;
    }

    final context = rootScaffoldMessengerKey.currentContext;
    if (context == null) return;
    await CampusActionExecutor.instance.execute(context, actionId);
  }
}
