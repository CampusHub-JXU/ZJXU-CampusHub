import 'dart:async';

import 'package:material_ui/material_ui.dart';
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
      case WechatActionTarget(:final url, :final searchKeyword):
        return _executeWechat(context, action, url, searchKeyword);
    }
  }

  Future<CampusActionResult> _executeWechat(
    BuildContext context,
    CampusAction action,
    String url,
    String? searchKeyword,
  ) {
    return executeWechat(
      context,
      url: url,
      title: action.title,
      searchKeyword: searchKeyword,
    );
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
  /// - [searchKeyword] 非空时把降级语义从「复制链接」换成「复制关键词到
  ///   微信搜一搜」：剪贴板写关键词而非 URL，手动复制动作文案同步切换。
  ///   公众号/小程序类入口必须给关键词（链接粘进微信地址栏打不开）。
  Future<CampusActionResult> executeWechat(
    BuildContext context, {
    required String url,
    required String title,
    String? successMessage,
    String? failureMessage,
    String? searchKeyword,
    bool autoCopyOnFailure = false,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await WechatLauncher.instance.openUrlDetailed(url);

    // 降级复制物：有搜索关键词写关键词（微信内搜一搜直达服务号/小程序），
    // 否则退回剥离一次性认证参数的干净链接。
    final copyText = (searchKeyword != null && searchKeyword.trim().isNotEmpty)
        ? searchKeyword.trim()
        : (result.sanitizedUrl.trim().isNotEmpty
              ? result.sanitizedUrl
              : sanitizeWechatShareUrl(url));
    final copyIsKeyword = copyText == searchKeyword?.trim();
    final copyActionLabel = copyIsKeyword ? '复制关键词' : '复制链接';

    // 「不支持外部直达」只能复制降级，自动复制一次省一步操作；其余失败按
    // 调用方开关决定是否先自动复制。
    final shouldAutoCopy =
        autoCopyOnFailure || result.status == WechatLaunchStatus.noHandler;
    var autoCopied = false;
    var autoCopyFailed = false;
    if (result.status != WechatLaunchStatus.launched &&
        result.status != WechatLaunchStatus.unsupportedUrl &&
        shouldAutoCopy) {
      autoCopied = await _copyToClipboard(copyText);
      autoCopyFailed = !autoCopied;
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
        successMessage ??
            (copyIsKeyword
                ? '已请求打开微信，目标页面打开结果无法确认；若未直达请复制关键词到微信「搜一搜」搜索「$copyText」'
                : '已请求打开微信，目标页面打开结果无法确认；若未直达请复制链接'),
      WechatLaunchStatus.noHandler => switch (wechatAppResult?.status) {
        WechatLaunchStatus.launched =>
          autoCopied
              ? (copyIsKeyword
                    ? '微信不支持外部直达，已复制「$copyText」并打开微信，请在微信「搜一搜」粘贴搜索'
                    : '微信不支持外部直达该网页，已复制链接并打开微信，请在微信内粘贴打开')
              : (copyIsKeyword
                    ? '微信不支持外部直达，已打开微信；可点「复制关键词」后到「搜一搜」搜索「$copyText」'
                    : '微信不支持外部直达该网页，已打开微信；可点击复制链接后粘贴打开'),
        // 未安装微信始终如实说明，不用通用 failureMessage 掩盖真实原因。
        WechatLaunchStatus.notInstalled =>
          autoCopied
              ? (copyIsKeyword
                    ? '未检测到微信，「$copyText」已复制，可在微信「搜一搜」粘贴搜索'
                    : '未检测到微信，链接已复制，请在微信中粘贴打开')
              : (copyIsKeyword
                    ? '未检测到微信，可复制关键词「$copyText」到微信「搜一搜」搜索'
                    : '未检测到微信，可复制链接后到微信中打开'),
        _ =>
          autoCopied
              ? (failureMessage ??
                    (copyIsKeyword
                        ? '微信不支持外部直达，「$copyText」已复制，请在微信「搜一搜」粘贴搜索'
                        : '微信不支持外部直达该网页，链接已复制，请到微信中粘贴打开'))
              : (copyIsKeyword
                    ? '微信不支持外部直达，请点「复制关键词」后到微信「搜一搜」搜索「$copyText」'
                    : '微信不支持外部直达该网页，请复制链接后在微信中粘贴打开'),
      },
      // 未安装微信始终如实说明，不用通用 failureMessage 掩盖真实原因。
      WechatLaunchStatus.notInstalled =>
        autoCopied
            ? (copyIsKeyword
                  ? '未检测到微信，「$copyText」已复制，可在微信「搜一搜」粘贴搜索'
                  : '未检测到微信，链接已复制，请在微信中粘贴打开')
            : (copyIsKeyword
                  ? '未检测到微信，可复制关键词「$copyText」到微信「搜一搜」搜索'
                  : '未检测到微信，可复制链接后到微信中打开'),
      WechatLaunchStatus.unsupportedUrl => '链接格式不支持，无法在微信中打开',
      WechatLaunchStatus.launchFailed ||
      WechatLaunchStatus.channelUnavailable =>
        autoCopied
            ? (failureMessage ??
                  (copyIsKeyword
                      ? '未能拉起微信，「$copyText」已复制，请在微信「搜一搜」粘贴搜索'
                      : '未能拉起微信，链接已复制，请在微信中粘贴打开'))
            : autoCopyFailed
            ? (copyIsKeyword
                  ? '无法拉起微信且关键词复制失败，请在微信「搜一搜」手动搜索「$copyText」'
                  : '无法拉起微信且链接复制失败，可截屏后手动输入网址')
            : (copyIsKeyword
                  ? '无法拉起微信，请点「复制关键词」后到微信「搜一搜」搜索「$copyText」'
                  : '无法拉起微信，请复制链接后到微信中打开'),
    };

    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: SnackBarAction(
            label: copyActionLabel,
            onPressed: () => unawaited(
              copyTextWithFeedback(
                context,
                copyText,
                doneLabel: copyIsKeyword ? '关键词已复制' : '链接已复制',
              ),
            ),
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
