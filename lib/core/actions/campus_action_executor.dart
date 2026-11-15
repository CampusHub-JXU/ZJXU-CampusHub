import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/copy_text_feedback.dart';
import 'campus_action.dart';
import 'campus_action_registry.dart';
import '../wechat/wechat_launcher.dart';

/// CampusAction 执行器（PRD 0.7.0 §6）。
///
/// Feature / Widget / Shortcut / Deep Link 只提交 action id，由本类决定实际
/// 启动方式并统一处理 WeChat 复制 fallback。WebView 入口统一走 Route 目标
/// （`external-webview` + extra）。
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
  /// - 始终提供「复制链接」动作（失败时用户可手动复制），复制内容是剥离了
  ///   一次性认证参数的干净链接（见 [sanitizeWechatShareUrl]）。
  /// - [autoCopyOnFailure] 为 true 时，拉起失败先自动复制一次；「微信不支持
  ///   外部直达」（`noHandler`）无论该开关如何都会自动复制，并随后尝试经
  ///   [WechatLauncher.openWeChatApp] 把微信 App 请到前台，由用户粘贴打开。
  /// - [successMessage] / [failureMessage] 允许调用方覆盖文案；
  ///   [failureMessage] 仅在自动复制成功且微信 App 未能拉起的「不支持直达 /
  ///   拉起失败」场景使用，未安装微信时始终如实提示。
  /// - 文案与状态必须诚实：`launched` 只代表 intent 已发出，不代表微信内
  ///   页面真的打开，文案不得断言「已打开」；`noHandler` 即使成功拉起微信
  ///   App 也只算降级路径，返回 [CampusActionStatus.fallbackAvailable]。
  Future<CampusActionResult> executeWechat(
    BuildContext context, {
    required String url,
    required String title,
    String? successMessage,
    String? failureMessage,
    bool autoCopyOnFailure = false,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await WechatLauncher.instance.openUrlDetailed(url);

    // 复制降级用干净链接：优先通道回报值，回退到本地清理结果。
    final copyUrl = result.sanitizedUrl.trim().isNotEmpty
        ? result.sanitizedUrl
        : sanitizeWechatShareUrl(url);

    // 「不支持外部直达」只能复制降级，自动复制一次省一步操作；其余失败按
    // 调用方开关决定是否先自动复制。
    final shouldAutoCopy =
        autoCopyOnFailure || result.status == WechatLaunchStatus.noHandler;
    var autoCopied = false;
    if (result.status != WechatLaunchStatus.launched &&
        result.status != WechatLaunchStatus.unsupportedUrl &&
        shouldAutoCopy) {
      autoCopied = await _copyToClipboard(copyUrl);
    }

    // 微信内无外部直达入口（noHandler）：复制后再拉起微信 App 本体，由用户粘贴
    // 打开。结果诚实上报：微信被拉起 ≠ 目标网页已打开，状态仍是降级而非成功。
    WechatLaunchResult? wechatAppResult;
    if (result.status == WechatLaunchStatus.noHandler) {
      wechatAppResult = await WechatLauncher.instance.openWeChatApp();
    }

    final launched = result.status == WechatLaunchStatus.launched;
    final text = switch (result.status) {
      WechatLaunchStatus.launched =>
        successMessage ?? '已请求打开微信，目标页面打开结果无法确认；若未直达请复制链接',
      WechatLaunchStatus.noHandler => switch (wechatAppResult?.status) {
        WechatLaunchStatus.launched =>
          autoCopied
              ? '微信不支持外部直达该网页，已复制链接并打开微信，请在微信内粘贴打开'
              : '微信不支持外部直达该网页，已打开微信；可点击复制链接后粘贴打开',
        // 未安装微信始终如实说明，不用通用 failureMessage 掩盖真实原因。
        WechatLaunchStatus.notInstalled =>
          autoCopied ? '未检测到微信，链接已复制，请在微信中粘贴打开' : '未检测到微信，可复制链接后到微信中打开',
        _ =>
          autoCopied
              ? (failureMessage ?? '微信不支持外部直达该网页，链接已复制，请到微信中粘贴打开')
              : '微信不支持外部直达该网页，请复制链接后在微信中粘贴打开',
      },
      // 未安装微信始终如实说明，不用通用 failureMessage 掩盖真实原因。
      WechatLaunchStatus.notInstalled =>
        autoCopied ? '未检测到微信，链接已复制，请在微信中粘贴打开' : '未检测到微信，可复制链接后到微信中打开',
      WechatLaunchStatus.unsupportedUrl => '链接格式不支持，无法在微信中打开',
      WechatLaunchStatus.launchFailed ||
      WechatLaunchStatus.channelUnavailable =>
        autoCopied
            ? (failureMessage ?? '未能拉起微信，链接已复制，请在微信中粘贴打开')
            : '无法拉起微信，请复制链接后到微信中打开',
    };

    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: SnackBarAction(
            label: '复制链接',
            onPressed: () => unawaited(copyTextWithFeedback(context, copyUrl)),
          ),
        ),
      );

    final status = launched
        ? CampusActionStatus.success
        : result.status == WechatLaunchStatus.unsupportedUrl
        ? CampusActionStatus.failed
        : CampusActionStatus.fallbackAvailable;
    return CampusActionResult(status, message: text);
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
