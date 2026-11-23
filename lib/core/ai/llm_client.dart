import 'dart:convert';

import 'package:dio/dio.dart';

import '../network/proxy_mode.dart';
import 'llm_profile.dart';

class LlmMessage {
  const LlmMessage({required this.role, required this.content})
    : assert(role == 'system' || role == 'user' || role == 'assistant');

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

class LlmStreamDelta {
  const LlmStreamDelta({
    this.contentDelta,
    this.reasoningDelta,
    this.finishReason,
  });

  final String? contentDelta;
  final String? reasoningDelta;
  final String? finishReason;
}

class LlmCompletionResult {
  const LlmCompletionResult({
    required this.content,
    required this.model,
    this.reasoningContent,
  });

  final String content;
  final String? reasoningContent;
  final String model;
}

class LlmConnectionTestResult {
  const LlmConnectionTestResult({
    required this.latencyMs,
    required this.response,
  });

  final int latencyMs;
  final LlmCompletionResult response;
  String get content => response.content;
  String get model => response.model;
}

enum LlmErrorKind {
  notConfigured('请先填写 AI 服务地址、模型和 API Key。'),
  unauthorized('AI 服务认证失败，请检查 API Key 和访问权限。'),
  rateLimit('AI 服务请求过于频繁或额度不足，请稍后重试。'),
  badRequest('AI 服务拒绝了请求，请检查服务地址和模型配置。'),
  serverError('AI 服务暂时异常，请稍后重试。'),
  network('无法连接 AI 服务，请检查网络后重试。'),
  cancelled('AI 请求已取消。'),
  invalidResponse('AI 服务返回了无法识别的响应。');

  const LlmErrorKind(this.message);

  final String message;
}

class LlmException implements Exception {
  const LlmException(this.kind);

  final LlmErrorKind kind;
  String get message => kind.message;

  @override
  String toString() => message;
}

class LlmClient {
  LlmClient({Dio? dio, bool ignoreSystemProxy = false})
    : _dio = dio ?? _createDio(ignoreSystemProxy);

  final Dio _dio;

  static Dio _createDio(bool ignoreSystemProxy) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    applyProxyModeToDio(dio, ignoreSystemProxy: ignoreSystemProxy);
    return dio;
  }

  Future<LlmCompletionResult> chatCompletions({
    required LlmProfile profile,
    required String apiKey,
    required List<LlmMessage> messages,
    double? temperature,
    int? maxTokens,
    bool jsonMode = false,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _post<Object?>(
        profile: profile,
        apiKey: apiKey,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        jsonMode: jsonMode,
        stream: false,
        cancelToken: cancelToken,
      );
      final Object? data = response.data;
      final payload = _readObject(data is String ? jsonDecode(data) : data);
      final choice = _firstChoice(payload);
      final message = _readObject(choice?['message']);
      final content = message['content'] as String?;
      final reasoning = message['reasoning_content'] as String?;
      if (content == null && reasoning == null) {
        throw const LlmException(LlmErrorKind.invalidResponse);
      }
      return LlmCompletionResult(
        content: content ?? '',
        reasoningContent: reasoning,
        model: payload['model'] as String? ?? profile.model.trim(),
      );
    } on Object catch (error) {
      throw _mapError(error);
    }
  }

  Stream<LlmStreamDelta> streamChatCompletions({
    required LlmProfile profile,
    required String apiKey,
    required List<LlmMessage> messages,
    double? temperature,
    int? maxTokens,
    bool jsonMode = false,
    CancelToken? cancelToken,
  }) async* {
    // Own the transport token so ending this stream cannot cancel other requests.
    final transportToken = CancelToken();
    CancelToken? forwardedToken = transportToken;
    if (cancelToken?.isCancelled ?? false) {
      throw const LlmException(LlmErrorKind.cancelled);
    }
    cancelToken?.whenCancel.then((_) => forwardedToken?.cancel());
    try {
      final response = await _post<ResponseBody>(
        profile: profile,
        apiKey: apiKey,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        jsonMode: jsonMode,
        stream: true,
        cancelToken: transportToken,
      );
      final body = response.data;
      if (body == null) {
        throw const LlmException(LlmErrorKind.invalidResponse);
      }

      var finished = false;
      final lines = const LineSplitter().bind(utf8.decoder.bind(body.stream));
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') return;

        final choice = _firstChoice(_readObject(jsonDecode(data)));
        if (choice == null) continue;
        final finishReason = choice['finish_reason'] as String?;
        final rawDelta = choice['delta'];
        final delta = rawDelta == null && finishReason != null
            ? const <String, dynamic>{}
            : _readObject(rawDelta);
        final content = delta['content'] as String?;
        final reasoning = delta['reasoning_content'] as String?;
        if (finishReason != null) finished = true;
        if (content != null || reasoning != null || finishReason != null) {
          yield LlmStreamDelta(
            contentDelta: content,
            reasoningDelta: reasoning,
            finishReason: finishReason,
          );
        }
      }
      if (!finished) {
        throw const LlmException(LlmErrorKind.invalidResponse);
      }
    } on Object catch (error) {
      throw _mapError(error);
    } finally {
      forwardedToken = null;
      if (!transportToken.isCancelled) transportToken.cancel();
    }
  }

  Future<LlmConnectionTestResult> testConnection(
    LlmProfile profile,
    String apiKey,
  ) async {
    final stopwatch = Stopwatch()..start();
    final result = await chatCompletions(
      profile: profile,
      apiKey: apiKey,
      messages: const [LlmMessage(role: 'user', content: 'Reply with OK.')],
      maxTokens: 16,
    );
    return LlmConnectionTestResult(
      latencyMs: stopwatch.elapsedMilliseconds,
      response: result,
    );
  }

  Future<Response<T>> _post<T>({
    required LlmProfile profile,
    required String apiKey,
    required List<LlmMessage> messages,
    required double? temperature,
    required int? maxTokens,
    required bool jsonMode,
    required bool stream,
    required CancelToken? cancelToken,
  }) async {
    final key = apiKey.trim();
    final baseUrl = profile.baseUrl.trim();
    final model = profile.model.trim();
    if (key.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      throw const LlmException(LlmErrorKind.notConfigured);
    }
    final baseUri = Uri.tryParse(baseUrl);
    if (baseUri == null ||
        (baseUri.scheme != 'https' && baseUri.scheme != 'http') ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasFragment ||
        baseUri.hasQuery) {
      throw const LlmException(LlmErrorKind.badRequest);
    }
    final path = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
    final tokenLimit = maxTokens ?? profile.maxTokens;
    final response = await _dio.postUri<T>(
      baseUri.replace(path: '$path/chat/completions'),
      data: {
        'model': model,
        'messages': messages.map((message) => message.toJson()).toList(),
        'temperature': temperature ?? profile.temperature,
        'max_tokens': ?tokenLimit,
        'stream': stream,
        if (jsonMode) 'response_format': {'type': 'json_object'},
      },
      options: Options(
        contentType: Headers.jsonContentType,
        responseType: stream ? ResponseType.stream : ResponseType.json,
        followRedirects: false,
        receiveDataWhenStatusError: false,
        headers: {
          'Authorization': 'Bearer $key',
          'Accept': stream ? 'text/event-stream' : Headers.jsonContentType,
        },
      ),
      cancelToken: cancelToken,
    );
    final status = response.statusCode;
    if (status != null && (status < 200 || status >= 300)) {
      throw LlmException(_statusError(status));
    }
    return response;
  }

  static Map<String, dynamic> _readObject(Object? value) {
    if (value is Map<String, dynamic>) return value;
    throw const LlmException(LlmErrorKind.invalidResponse);
  }

  static Map<String, dynamic>? _firstChoice(Map<String, dynamic> payload) {
    final choices = payload['choices'];
    if (choices is! List) {
      throw const LlmException(LlmErrorKind.invalidResponse);
    }
    return choices.isEmpty ? null : _readObject(choices.first);
  }

  static LlmException _mapError(Object error) {
    if (error is LlmException) return error;
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) {
        return const LlmException(LlmErrorKind.cancelled);
      }
      final status = error.response?.statusCode;
      if (status != null && (status < 200 || status >= 300)) {
        return LlmException(_statusError(status));
      }
      return _mapError(error.error ?? error.type);
    }
    if (error is FormatException || error is TypeError) {
      return const LlmException(LlmErrorKind.invalidResponse);
    }
    return const LlmException(LlmErrorKind.network);
  }

  static LlmErrorKind _statusError(int status) => switch (status) {
    401 || 403 => LlmErrorKind.unauthorized,
    429 => LlmErrorKind.rateLimit,
    400 || 404 || 422 => LlmErrorKind.badRequest,
    >= 500 && < 600 => LlmErrorKind.serverError,
    _ => LlmErrorKind.invalidResponse,
  };
}
