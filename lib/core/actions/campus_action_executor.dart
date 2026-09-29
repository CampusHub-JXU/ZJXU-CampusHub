import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/copy_text_feedback.dart';
import '../../shared/widgets/external_url_launcher.dart';
import 'campus_action.dart';
import 'campus_action_registry.dart';
import '../wechat/wechat_launcher.dart';

/// CampusAction 执行器（PRD 0.7.0 §6）。
///
/// Feature / Widget / Shortcut / Deep Link 只提交 action id，由本类决定实际
/// 启动方式并统一处理 WeChat 复制 fallback。Web / ProtectedWeb / Native 目标
/// 在对应 Phase 接入前返回 unsupported。
class CampusActionExecutor {
  CampusActionExecutor._();

  static final CampusActionExecutor instance = CampusActionExecutor._();

  Future<CampusActionResult> execute(
    BuildContext context,
    String actionId,
  ) async {
    final action = CampusActionRegistry.instance.findById(actionId);
    if (action == null) {
      return const CampusActionResult(
        CampusActionStatus.unsupported,
        message: '该功能入口尚未注册',
      );
    }
    if (!context.mounted) {
      return const CampusActionResult(CampusActionStatus.failed);
    }

    switch (action.target) {
      case RouteActionTarget(:final routeName, :final extra):
        await context.pushNamed(routeName, extra: extra);
        return const CampusActionResult(CampusActionStatus.success);
      case WechatActionTarget(:final url):
        return _executeWechat(context, action, url);
      case ExternalActionTarget(:final url):
        final opened = await openInExternalBrowser(
          url,
          logPrefix: 'CampusAction',
        );
        return opened
            ? const CampusActionResult(CampusActionStatus.success)
            : const CampusActionResult(
                CampusActionStatus.targetUnavailable,
                message: '无法打开外部链接',
              );
      case WebActionTarget():
      case ProtectedWebActionTarget():
      case NativeActionTarget():
        return const CampusActionResult(
          CampusActionStatus.unsupported,
          message: '该入口尚未接入',
        );
    }
  }

  Future<CampusActionResult> _executeWechat(
    BuildContext context,
    CampusAction action,
    String url,
  ) {
    return executeWechat(context, url: url, title: action.title);
  }

  /// 统一的微信公众号 / H5 拉起 + 复制 fallback（Feature 直连入口复用）。
  ///
  /// - 始终提供「复制链接」动作（失败时用户可手动复制）。
  /// - [autoCopyOnFailure] 为 true 时，拉起失败先自动复制一次。
  /// - [successMessage] / [failureMessage] 允许调用方覆盖文案；
  ///   [failureMessage] 仅在自动复制成功时使用。
  Future<CampusActionResult> executeWechat(
    BuildContext context, {
    required String url,
    required String title,
    String? successMessage,
    String? failureMessage,
    bool autoCopyOnFailure = false,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final opened = await WechatLauncher.instance.openUrl(url);

    var autoCopied = false;
    if (!opened && autoCopyOnFailure) {
      autoCopied = await _copyToClipboard(url);
    }

    final text = opened
        ? (successMessage ?? '已跳转到微信，请在微信中打开$title')
        : autoCopied
        ? (failureMessage ?? '未能打开页面，充值链接已复制，请到微信中打开')
        : '未能打开页面，可复制链接后到微信中打开';

    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: SnackBarAction(
            label: '复制链接',
            onPressed: () => unawaited(copyTextWithFeedback(context, url)),
          ),
        ),
      );

    return CampusActionResult(
      opened
          ? CampusActionStatus.success
          : CampusActionStatus.fallbackAvailable,
    );
  }

  Future<bool> _copyToClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } on PlatformException {
      return false;
    }
  }
}
