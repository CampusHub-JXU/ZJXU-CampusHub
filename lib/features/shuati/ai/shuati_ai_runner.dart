/// 刷题助手 LLM 适配器：把 [ShuatiAiLlmRunner] 落到 `lib/core/ai`
/// （`LlmConfigController` + `LlmClient`）的 OpenAI 兼容端点上。
///
/// 页面 / 测试通过 `ShuatiServices.aiServiceFactory` 注入实现；
/// 本类只负责「读当前生效配置 → 发一次补全 → 映射结果」。
library;

import '../../../core/ai/llm_client.dart';
import '../../../core/ai/llm_config_controller.dart';
import '../../../core/ai/llm_profile.dart';
import 'shuati_ai_models.dart';

/// 发一次 chat completion（测试注入 fake，默认走 [LlmClient]）。
typedef ShuatiAiChatCompletion = Future<LlmCompletionResult> Function(
  LlmProfile profile,
  String apiKey,
  String prompt,
  int? maxTokens,
);

/// 基于全局 AI 配置的真实 runner（Issue #117）。
///
/// 每次调用重新读 `LlmConfigController.instance.activeProfile` /
/// `activeApiKey`（用户在设置里改配置立即生效）；未配置时抛
/// [ShuatiAiFailure] 提示去设置。
class CoreAiShuatiRunner implements ShuatiAiLlmRunner {
  CoreAiShuatiRunner({
    LlmConfigController? config,
    LlmClient? client,
    ShuatiAiChatCompletion? complete,
  }) : _config = config ?? LlmConfigController.instance,
       _complete = complete ?? _withClient(client ?? LlmClient());

  final LlmConfigController _config;
  final ShuatiAiChatCompletion _complete;

  static ShuatiAiChatCompletion _withClient(LlmClient client) =>
      (profile, apiKey, prompt, maxTokens) => client.chatCompletions(
        profile: profile,
        apiKey: apiKey,
        messages: [LlmMessage(role: 'user', content: prompt)],
        maxTokens: maxTokens,
      );

  @override
  Future<ShuatiAiCompletion> complete(ShuatiAiRequest request) async {
    await _config.init();
    final profile = _config.activeProfile;
    final apiKey = _config.activeApiKey.trim();
    if (profile == null ||
        apiKey.isEmpty ||
        profile.baseUrl.trim().isEmpty ||
        profile.model.trim().isEmpty) {
      throw const ShuatiAiFailure('请先在设置中配置 AI 模型与 API Key');
    }
    try {
      final result = await _complete(
        profile,
        apiKey,
        request.prompt,
        request.maxTokens,
      );
      final model = result.model.trim();
      return ShuatiAiCompletion(
        text: result.content,
        model: model.isEmpty ? profile.model : model,
      );
    } on LlmException catch (e) {
      throw ShuatiAiFailure(e.message, cause: e);
    }
  }
}
