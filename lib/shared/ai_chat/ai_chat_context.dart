import 'package:flutter/widgets.dart';

/// 「需登录」态的模块错误标记：放入 [AiChatContextModule.error]，
/// 页面据此把芯片动作渲染为「需登录」并走 [AiChatContextProvider.requestLogin]。
const String kAiChatContextNeedsLogin = '需登录';

/// 「已过期」态标记：模块已有数据（`isReady == true`）但标记为过期，
/// 页面把芯片动作渲染为「已过期·刷新」。
const String kAiChatContextStale = '已过期';

/// 学业上下文芯片栏中的一个可选模块（对 `features/ai_export` 的中性抽象）。
class AiChatContextModule {
  const AiChatContextModule({
    required this.id,
    required this.label,
    required this.selected,
    required this.isReady,
    required this.isLoading,
    this.error,
  });

  /// 稳定标识，如 `grades`。
  final String id;
  final String label;
  final bool selected;

  /// 已有可用数据（含「已过期」数据——仍会被带进上下文）。
  final bool isReady;

  /// 正在获取中。
  final bool isLoading;

  /// 非就绪原因 / 状态标记：
  /// [kAiChatContextNeedsLogin] 需登录、[kAiChatContextStale] 已过期、
  /// 其余为用户可读的失败原因；`null` 表示无异常。
  final String? error;
}

/// AI 对话的可插拔上下文提供者：向 [AiChatController] / `AiChatPage`
/// 暴露「可选模块 + 就绪状态 + 上下文文本」契约，隐藏具体业务实现
/// （如 `features/ai_export` 的导出控制器）。组合层（`lib/app`）负责桥接。
abstract class AiChatContextProvider extends ChangeNotifier {
  /// 所有可用模块（含未勾选的），供芯片栏渲染。
  List<AiChatContextModule> get modules;

  /// 已勾选且已就绪的模块数。
  int get readyCount;

  /// 已勾选的模块数。
  int get selectedCount;

  /// 是否有模块正在获取中。
  bool get isBusy;

  /// 初始化本地缓存等；可重复调用，实现应幂等。
  Future<void> initialize();

  /// 勾选 / 取消勾选某个模块。
  void toggleModule(String id, bool selected);

  /// 确保所有已勾选模块就绪（缺失 / 过期 / 失败的选择性补齐）。
  /// 实现自行决定补齐策略；失败不抛出，只更新模块状态。
  Future<void> ensureSelectedReady();

  /// 构建注入 `system` 提示词的上下文文本；无可注入内容时返回空串。
  /// 对相同数据应返回稳定文本（`AiChatController` 以文本指纹去重）。
  String buildContextText();

  /// 芯片「需登录」动作的执行入口。由组合层桥接具体登录流程；
  /// 返回登录是否成功。默认实现不支持登录，恒为 `false`。
  Future<bool> requestLogin(BuildContext context, String moduleId) async =>
      false;

  /// 因账号切换 / 登出而清空过数据（页面据此给一次性提示）。
  bool get identityReset => false;

  /// 确认并清除 [identityReset] 提示。默认空实现。
  void acknowledgeIdentityReset() {}
}
