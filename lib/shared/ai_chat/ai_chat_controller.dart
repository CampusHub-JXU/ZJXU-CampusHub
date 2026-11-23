import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/ai/llm_client.dart';
import '../../core/ai/llm_config_controller.dart';
import '../../core/ai/llm_profile.dart';
import 'ai_chat_context.dart';

/// 聊天消息角色。
enum AiChatRole { user, assistant }

/// 单条 AI 对话消息。
class AiChatMessage {
  const AiChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.reasoningContent,
    this.isStreaming = false,
    this.errorMessage,
  });

  final String id;
  final AiChatRole role;
  final String content;
  final String? reasoningContent;
  final bool isStreaming;
  final String? errorMessage;

  bool get hasReasoning =>
      reasoningContent != null && reasoningContent!.trim().isNotEmpty;

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;

  AiChatMessage copyWith({
    String? content,
    String? reasoningContent,
    bool? isStreaming,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AiChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      reasoningContent: reasoningContent ?? this.reasoningContent,
      isStreaming: isStreaming ?? this.isStreaming,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// AI 对话状态机：管理消息列表、流式取消令牌，以及学业上下文与固定上下文的
/// 精简 `system` 提示词注入。
///
/// 学业上下文经 [AiChatContextProvider] 抽象注入（组合层在 `lib/app`
/// 桥接具体实现），shared 层不依赖任何业务 feature。
class AiChatController extends ChangeNotifier {
  AiChatController({
    LlmConfigController? configController,
    LlmClient? llmClient,
    this.contextProvider,
    String? fixedContext,
    DateTime Function()? clock,
  }) : _configController = configController ?? LlmConfigController.instance,
       _llmClient = llmClient ?? LlmClient(),
       _fixedContext = _normalizeOptional(fixedContext),
       _clock = clock ?? DateTime.now {
    _configController.addListener(_onDependencyChanged);
    contextProvider?.addListener(_onDependencyChanged);
  }

  static const String _baseSystemPrompt =
      '你是嘉兴大学 CampusHub 的学业助手。请基于提供的上下文客观、准确地回答用户问题；'
      '未提供的数据不要编造，成绩、绩点与学分最终以教务系统为准。';

  final LlmConfigController _configController;
  final LlmClient _llmClient;
  final AiChatContextProvider? contextProvider;
  final String? _fixedContext;
  final DateTime Function() _clock;

  final List<AiChatMessage> _messages = [];
  bool _isGenerating = false;
  bool _disposed = false;
  int _nextMessageId = 0;
  int _activeRequestId = 0;
  CancelToken? _cancelToken;

  /// 上一次已随请求发送的学业上下文文本；用于判断「首条或变化时」再重算，
  /// 未变化时不重复生成或刷屏附加。
  String? _lastSentAcademicSignature;
  String _cachedAcademicText = '';
  int _contextSyncCount = 0;

  List<AiChatMessage> get messages => List.unmodifiable(_messages);

  bool get isGenerating => _isGenerating;

  LlmConfigController get configController => _configController;

  bool get isConfigured => _configController.isConfigured;

  LlmProfile? get activeProfile => _configController.activeProfile;

  String? get fixedContext => _fixedContext;

  /// 已向底层模型同步过的非空学业上下文版本次数（首条或变化时递增）。
  int get contextSyncCount => _contextSyncCount;

  /// 已勾选且已就绪的上下文模块数。
  int get readySelectedContextCount => contextProvider?.readyCount ?? 0;

  /// 初始化配置与本地学业缓存。
  Future<void> initialize() async {
    await Future.wait([
      _configController.init(),
      if (contextProvider != null) contextProvider!.initialize(),
    ]);
  }

  /// 发送一条用户消息并启动流式回复。
  Future<void> sendMessage(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty || _isGenerating || _disposed) return;

    final userMessage = AiChatMessage(
      id: _allocateId('user'),
      role: AiChatRole.user,
      content: text,
    );
    _messages.add(userMessage);

    final profile = _configController.activeProfile;
    final apiKey = _configController.activeApiKey.trim();
    if (!_configController.isConfigured || profile == null || apiKey.isEmpty) {
      _messages.add(
        AiChatMessage(
          id: _allocateId('assistant'),
          role: AiChatRole.assistant,
          content: '',
          errorMessage: LlmErrorKind.notConfigured.message,
        ),
      );
      _notify();
      return;
    }

    await _streamReplyForMessages(profile: profile, apiKey: apiKey);
  }

  /// 重试上一条失败的回复。
  Future<void> retryLast() async {
    if (_isGenerating || _disposed || _messages.isEmpty) return;
    final last = _messages.last;
    if (last.role != AiChatRole.assistant || !last.hasError) return;

    final profile = _configController.activeProfile;
    final apiKey = _configController.activeApiKey.trim();
    if (!_configController.isConfigured || profile == null || apiKey.isEmpty) {
      return;
    }

    _messages.removeLast();
    await _streamReplyForMessages(profile: profile, apiKey: apiKey);
  }

  /// 中断当前流式输出，保留已生成的片段。
  void stopGeneration() {
    if (!_isGenerating) return;
    _activeRequestId++;
    final token = _cancelToken;
    _cancelToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('stopped_by_user');
    }
    _isGenerating = false;
    if (_messages.isNotEmpty) {
      final last = _messages.last;
      if (last.role == AiChatRole.assistant && last.isStreaming) {
        final hasOutput = last.content.isNotEmpty || last.hasReasoning;
        _messages[_messages.length - 1] = last.copyWith(
          isStreaming: false,
          errorMessage: hasOutput ? null : '已停止生成',
        );
      }
    }
    _notify();
  }

  /// 清空消息并重置上下文发送状态。
  void clear() {
    if (_isGenerating) {
      _activeRequestId++;
      final token = _cancelToken;
      _cancelToken = null;
      if (token != null && !token.isCancelled) {
        token.cancel('cleared');
      }
      _isGenerating = false;
    }
    _messages.clear();
    _lastSentAcademicSignature = null;
    _cachedAcademicText = '';
    _contextSyncCount = 0;
    _notify();
  }

  Future<void> _streamReplyForMessages({
    required LlmProfile profile,
    required String apiKey,
  }) async {
    final assistantId = _allocateId('assistant');
    _messages.add(
      AiChatMessage(
        id: assistantId,
        role: AiChatRole.assistant,
        content: '',
        isStreaming: true,
      ),
    );
    _isGenerating = true;
    final requestId = ++_activeRequestId;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _notify();

    // 发送前按需补齐已勾选上下文（如本地缓存尚未读完）；
    // 上下文准备失败不阻塞对话。
    final provider = contextProvider;
    if (provider != null) {
      try {
        await provider.ensureSelectedReady();
      } on Object {
        // 上下文就绪失败不阻塞发送。
      }
      if (_disposed || requestId != _activeRequestId) return;
    }

    final requestMessages = _buildRequestMessages();
    try {
      final stream = _llmClient.streamChatCompletions(
        profile: profile,
        apiKey: apiKey,
        messages: requestMessages,
        cancelToken: cancelToken,
      );
      await for (final delta in stream) {
        if (_disposed || requestId != _activeRequestId) return;
        final index = _messages.indexWhere((m) => m.id == assistantId);
        if (index == -1) return;
        final current = _messages[index];
        final nextContent = delta.contentDelta != null
            ? '${current.content}${delta.contentDelta}'
            : current.content;
        final nextReasoning = delta.reasoningDelta != null
            ? '${current.reasoningContent ?? ''}${delta.reasoningDelta}'
            : current.reasoningContent;
        if (nextContent != current.content ||
            nextReasoning != current.reasoningContent) {
          _messages[index] = current.copyWith(
            content: nextContent,
            reasoningContent: nextReasoning,
          );
          _notify();
        }
      }

      if (_disposed || requestId != _activeRequestId) return;
      final index = _messages.indexWhere((m) => m.id == assistantId);
      if (index != -1) {
        final current = _messages[index];
        final hasOutput =
            current.content.trim().isNotEmpty || current.hasReasoning;
        _messages[index] = current.copyWith(
          isStreaming: false,
          errorMessage: hasOutput ? null : LlmErrorKind.invalidResponse.message,
        );
      }
    } on Object catch (error) {
      if (_disposed || requestId != _activeRequestId) return;
      final index = _messages.indexWhere((m) => m.id == assistantId);
      if (index != -1) {
        final current = _messages[index];
        final isCancelled =
            cancelToken.isCancelled ||
            (error is LlmException && error.kind == LlmErrorKind.cancelled);
        final hasOutput = current.content.isNotEmpty || current.hasReasoning;
        final errorMessage = isCancelled
            ? (hasOutput ? null : '已停止生成')
            : (error is LlmException
                  ? error.message
                  : LlmErrorKind.network.message);
        _messages[index] = current.copyWith(
          isStreaming: false,
          errorMessage: errorMessage,
        );
      }
    } finally {
      if (requestId == _activeRequestId) {
        _isGenerating = false;
        _cancelToken = null;
        _notify();
      }
    }
  }

  List<LlmMessage> _buildRequestMessages() {
    _syncAcademicContextCache();

    final systemBuffer = StringBuffer(_baseSystemPrompt);
    if (_fixedContext != null) {
      systemBuffer
        ..writeln()
        ..writeln()
        ..writeln('[当前上下文]')
        ..write(_fixedContext);
    }
    if (_cachedAcademicText.isNotEmpty) {
      systemBuffer
        ..writeln()
        ..writeln()
        ..writeln('[学业数据上下文]')
        ..write(_cachedAcademicText);
    }

    final result = <LlmMessage>[
      LlmMessage(role: 'system', content: systemBuffer.toString()),
    ];

    // 排除末尾刚插入的占位 assistant 消息，并跳过此前纯失败无正文的问答对。
    final historyEnd = _messages.length - 1;
    for (var i = 0; i < historyEnd; i++) {
      final msg = _messages[i];
      if (msg.role == AiChatRole.user) {
        final hasNextAssistant =
            i + 1 < historyEnd && _messages[i + 1].role == AiChatRole.assistant;
        if (hasNextAssistant) {
          final reply = _messages[i + 1];
          if (reply.hasError && reply.content.trim().isEmpty) {
            i++; // 跳过失败且无正文的那一轮。
            continue;
          }
        }
        result.add(LlmMessage(role: 'user', content: msg.content));
      } else {
        if (msg.content.trim().isEmpty) continue;
        result.add(LlmMessage(role: 'assistant', content: msg.content));
      }
    }
    return result;
  }

  /// 以上下文文本本身为指纹去重：文本未变化不重算、不重复计入同步次数。
  void _syncAcademicContextCache() {
    final provider = contextProvider;
    if (provider == null) {
      _lastSentAcademicSignature = '';
      _cachedAcademicText = '';
      return;
    }
    final signature = provider.buildContextText();
    if (_lastSentAcademicSignature != null &&
        signature == _lastSentAcademicSignature) {
      return;
    }
    _lastSentAcademicSignature = signature;
    _cachedAcademicText = signature;
    if (_cachedAcademicText.isNotEmpty) {
      _contextSyncCount++;
    }
  }

  String _allocateId(String prefix) =>
      '$prefix-${_clock().microsecondsSinceEpoch}-${_nextMessageId++}';

  static String? _normalizeOptional(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  void _onDependencyChanged() {
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _activeRequestId++;
    final token = _cancelToken;
    _cancelToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('disposed');
    }
    _configController.removeListener(_onDependencyChanged);
    contextProvider?.removeListener(_onDependencyChanged);
    super.dispose();
  }
}
