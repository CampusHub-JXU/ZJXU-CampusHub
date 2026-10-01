import 'package:flutter/material.dart';

import 'glass_dialog_route.dart';

/// 统一的轻提示 / 确认框 / 底部弹层入口（docs/ui-unification-plan.md §4.6）。
///
/// 页面不再直接调 `showSnackBar` / `showDialog` / `showModalBottomSheet`：
///
/// * 轻提示外观由全局 `snackBarTheme` 决定，这里只统一行为——默认先收起
///   当前那条再弹（连点不排队）、可选 [dedupeKey] 合并短时间内的同类提示、
///   没有 [ScaffoldMessenger] 时静默跳过；
/// * 确认框与底部弹层一律走亚克力弹层路由（[showGlassDialog] /
///   [showGlassModalBottomSheet]），亚克力关闭时自动降级为实色。
///
/// 网络异常提示继续用 `NetworkErrorToast.show`（带错误分类与文案映射）；
/// 复制提示继续用 `copyTextWithFeedback`。
abstract final class AppFeedback {
  static const Duration _dedupeWindow = Duration(seconds: 5);
  static final Map<String, DateTime> _lastShownAt = {};

  /// 弹一条轻提示。没有 [ScaffoldMessenger]（未挂载、测试）时静默跳过。
  static void toast(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
    String? dedupeKey,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    toastOn(
      messenger,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
      dedupeKey: dedupeKey,
    );
  }

  /// 同 [toast]，但用调用方在 `await` 之前捕获的 messenger，
  /// 免去异步回来后的 `mounted` 检查。
  static void toastOn(
    ScaffoldMessengerState messenger,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
    String? dedupeKey,
  }) {
    if (dedupeKey != null) {
      final now = DateTime.now();
      final last = _lastShownAt[dedupeKey];
      if (last != null && now.difference(last) < _dedupeWindow) return;
      _lastShownAt[dedupeKey] = now;
    }
    final action = actionLabel != null && onAction != null
        ? SnackBarAction(label: actionLabel, onPressed: onAction)
        : null;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: action,
          duration: duration ?? const Duration(seconds: 4),
        ),
      );
  }

  /// 收起当前轻提示。
  static void dismiss(BuildContext context) {
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  }

  /// 确认框：返回用户是否点了确认；点遮罩或返回键关闭视为取消。
  ///
  /// [destructive] 为 true 时确认按钮文字用 `error` 色（退出登录、清缓存、
  /// 关闭同步这类不可撤销的操作）。
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    String? message,
    String confirmLabel = '确定',
    String cancelLabel = '取消',
    bool destructive = false,
  }) async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          title: Text(title),
          content: message == null ? null : Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(cancelLabel),
            ),
            // 对话框按钮沿用文字按钮；不可撤销的动作用 error 色与「取消」拉开层级。
            TextButton(
              style: destructive
                  ? TextButton.styleFrom(foregroundColor: cs.error)
                  : null,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  /// 亚克力底部弹层。直接返回路由 future（不在内部 await），调用方需要
  /// 「弹层关闭」时机时可以自己挂回调。
  static Future<T?> sheet<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool scrollControlled = false,
    bool dragHandle = true,
    bool useSafeArea = true,
    BoxConstraints? constraints,
  }) {
    return showGlassModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: scrollControlled,
      showDragHandle: dragHandle,
      useSafeArea: useSafeArea,
      constraints: constraints,
    );
  }

  /// 清空去重记录，测试用。
  @visibleForTesting
  static void resetDedupe() => _lastShownAt.clear();
}
