import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/ai/llm_client.dart';
import 'package:jxu_campus_hub/core/ai/llm_profile.dart';

const _profile = LlmProfile(
  id: 'custom',
  name: '网关',
  preset: LlmProviderPreset.openaiCompatible,
  baseUrl: 'https://gateway.example/openai/v1/',
  model: 'gateway/model',
  temperature: 0.4,
  maxTokens: 256,
);
const _key = 'llm-test-secret';
const _messages = [
  LlmMessage(role: 'system', content: 'Respond in JSON.'),
  LlmMessage(role: 'user', content: '你好'),
];

void main() {
  late Dio dio;
  late LlmClient client;

  setUp(() {
    dio = Dio();
    client = LlmClient(dio: dio);
    addTearDown(() => dio.close(force: true));
  });

  test('发送兼容请求并读取文本、推理内容及模型', () async {
    dio.httpClientAdapter = _StubAdapter((request) {
      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'https://gateway.example/openai/v1/chat/completions',
      );
      expect(request.headers['authorization'], 'Bearer $_key');
      expect(request.headers.keys, isNot(contains('cookie')));
      expect(request.followRedirects, isFalse);
      expect(request.data, {
        'model': 'gateway/model',
        'messages': [
          {'role': 'system', 'content': 'Respond in JSON.'},
          {'role': 'user', 'content': '你好'},
        ],
        'temperature': 0.2,
        'max_tokens': 32,
        'stream': false,
        'response_format': {'type': 'json_object'},
      });
      return _jsonResponse(
        '{"model":"actual-model","choices":[{"message":'
        '{"content":"OK","reasoning_content":"推理"}}]}',
      );
    });

    final result = await client.chatCompletions(
      profile: _profile,
      apiKey: ' $_key ',
      messages: _messages,
      temperature: 0.2,
      maxTokens: 32,
      jsonMode: true,
    );

    expect(result.content, 'OK');
    expect(result.reasoningContent, '推理');
    expect(result.model, 'actual-model');
  });

  test('连接测试使用最小请求并返回延迟和模型响应', () async {
    dio.httpClientAdapter = _StubAdapter((request) {
      final body = request.data as Map<String, dynamic>;
      expect(body['max_tokens'], 16);
      expect(body['temperature'], _profile.temperature);
      expect(body['messages'], hasLength(1));
      expect(body, isNot(contains('response_format')));
      return _jsonResponse('{"choices":[{"message":{"content":"OK"}}]}');
    });

    final result = await client.testConnection(_profile, _key);
    expect(result.latencyMs, greaterThanOrEqualTo(0));
    expect(result.content, 'OK');
    expect(result.model, _profile.model);
  });

  test('SSE 跨字节分片读取推理、正文与结束原因，遇到 DONE 停止', () async {
    final bytes = utf8.encode(
      ': keep-alive\r\n\r\n'
      'data: {"choices":[{"delta":{"role":"assistant"}}]}\r\n\r\n'
      'data: {"choices":[{"delta":{"reasoning_content":"想"}}]}\r\n\r\n'
      'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n'
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
      'data: {"choices":[],"usage":{"total_tokens":16}}\n\n'
      'data: [DONE]\n\n'
      'data: invalid bytes after DONE\n\n',
    );
    dio.httpClientAdapter = _StubAdapter((request) {
      expect(request.headers['accept'], 'text/event-stream');
      final body = request.data as Map<String, dynamic>;
      expect(body['stream'], isTrue);
      expect(body['max_tokens'], _profile.maxTokens);
      return ResponseBody(
        Stream.fromIterable(bytes.map((byte) => Uint8List.fromList([byte]))),
        200,
      );
    });

    final deltas = await client
        .streamChatCompletions(
          profile: _profile,
          apiKey: _key,
          messages: _messages,
        )
        .toList();

    expect(deltas, hasLength(3));
    expect(deltas[0].reasoningDelta, '想');
    expect(deltas[1].contentDelta, '你好');
    expect(deltas[2].finishReason, 'stop');
  });

  test('SSE 正文可在流结束前消费，接收中取消会报告 cancelled', () async {
    final source = StreamController<Uint8List>();
    addTearDown(() => source.close());
    dio.httpClientAdapter = _StubAdapter(
      (_) => ResponseBody(source.stream, 200),
    );
    final token = CancelToken();
    final stream = client.streamChatCompletions(
      profile: _profile,
      apiKey: _key,
      messages: _messages,
      cancelToken: token,
    );

    final received = expectLater(
      stream.map((delta) {
        token.cancel(_key);
        return delta.contentDelta;
      }),
      emitsInOrder([
        'part',
        emitsError(_error(LlmErrorKind.cancelled)),
        emitsDone,
      ]),
    );
    source.add(
      Uint8List.fromList(
        utf8.encode('data: {"choices":[{"delta":{"content":"part"}}]}\n\n'),
      ),
    );
    await received;
  });

  test('SSE 缺少结束信号时报告 invalidResponse', () async {
    dio.httpClientAdapter = _StubAdapter(
      (_) => ResponseBody.fromString(
        'data: {"choices":[{"delta":{"content":"part"}}]}\n\n',
        200,
      ),
    );
    await expectLater(
      client.streamChatCompletions(
        profile: _profile,
        apiKey: _key,
        messages: _messages,
      ),
      emitsInOrder([
        isA<LlmStreamDelta>().having(
          (delta) => delta.contentDelta,
          'contentDelta',
          'part',
        ),
        emitsError(_error(LlmErrorKind.invalidResponse)),
        emitsDone,
      ]),
    );
  });

  for (final (status, kind) in [
    (400, LlmErrorKind.badRequest),
    (401, LlmErrorKind.unauthorized),
    (403, LlmErrorKind.unauthorized),
    (404, LlmErrorKind.badRequest),
    (422, LlmErrorKind.badRequest),
    (429, LlmErrorKind.rateLimit),
    (500, LlmErrorKind.serverError),
    (503, LlmErrorKind.serverError),
  ]) {
    test('HTTP $status 映射为 ${kind.name} 并隐藏响应正文', () async {
      dio.httpClientAdapter = _StubAdapter(
        (_) => _jsonResponse('{"error":"received key $_key"}', status),
      );
      await expectLater(
        client.chatCompletions(
          profile: _profile,
          apiKey: _key,
          messages: _messages,
        ),
        throwsA(_error(kind)),
      );
    });
  }

  test('空 Key 报告 notConfigured，网络异常报告 network', () async {
    dio.httpClientAdapter = _StubAdapter((request) {
      throw DioException.connectionError(requestOptions: request, reason: _key);
    });
    await expectLater(
      client.chatCompletions(
        profile: _profile,
        apiKey: ' ',
        messages: _messages,
      ),
      throwsA(_error(LlmErrorKind.notConfigured)),
    );
    await expectLater(
      client.chatCompletions(
        profile: _profile,
        apiKey: _key,
        messages: _messages,
      ),
      throwsA(_error(LlmErrorKind.network)),
    );
  });

  test('listModels 解析 data 中的 Map 与 String，去重保序', () async {
    dio.httpClientAdapter = _StubAdapter((request) {
      expect(request.method, 'GET');
      expect(
        request.uri.toString(),
        'https://gateway.example/openai/v1/models',
      );
      expect(request.headers['authorization'], 'Bearer $_key');
      expect(request.headers['accept'], 'application/json');
      expect(request.followRedirects, isFalse);
      expect(request.data, isNull);
      return _jsonResponse(
        '{"data":['
        '{"id":"auto/deepseek-v4.1-flash","display_name":"DeepSeek V4.1 Flash"},'
        '{"id":"auto/grok-4.7"},'
        '"auto/deepseek-v4.1-flash",'
        '{"other":"no-id"},'
        '123,'
        '"plain/model"]}',
      );
    });

    final models = await client.listModels(
      baseUrl: ' ${_profile.baseUrl} ',
      apiKey: ' $_key ',
    );

    expect(models.map((option) => option.id).toList(), [
      'auto/deepseek-v4.1-flash',
      'auto/grok-4.7',
      'plain/model',
    ]);
    expect(models[0].displayName, 'DeepSeek V4.1 Flash');
    expect(models[1].displayName, isNull);
    expect(models[2].displayName, isNull);
  });

  test('listModels 401 映射为 unauthorized，网络异常映射为 network', () async {
    dio.httpClientAdapter = _StubAdapter(
      (_) => _jsonResponse('{"error":"unauthorized"}', 401),
    );
    await expectLater(
      client.listModels(baseUrl: _profile.baseUrl, apiKey: _key),
      throwsA(_error(LlmErrorKind.unauthorized)),
    );

    dio.httpClientAdapter = _StubAdapter((request) {
      throw DioException.connectionError(requestOptions: request, reason: _key);
    });
    await expectLater(
      client.listModels(baseUrl: _profile.baseUrl, apiKey: _key),
      throwsA(_error(LlmErrorKind.network)),
    );
  });

  test(
    'listModels 缺 URL 或 Key 报告 notConfigured，非法 URL 报告 badRequest',
    () async {
      await expectLater(
        client.listModels(baseUrl: _profile.baseUrl, apiKey: ' '),
        throwsA(_error(LlmErrorKind.notConfigured)),
      );
      await expectLater(
        client.listModels(baseUrl: ' ', apiKey: _key),
        throwsA(_error(LlmErrorKind.notConfigured)),
      );
      await expectLater(
        client.listModels(baseUrl: 'not a url', apiKey: _key),
        throwsA(_error(LlmErrorKind.badRequest)),
      );
    },
  );

  test('listModels 响应缺少 data 列表时报告 invalidResponse', () async {
    for (final payload in ['{"data":{"x":1}}', '{}', '[1,2]']) {
      dio.httpClientAdapter = _StubAdapter((_) => _jsonResponse(payload));
      await expectLater(
        client.listModels(baseUrl: _profile.baseUrl, apiKey: _key),
        throwsA(_error(LlmErrorKind.invalidResponse)),
      );
    }
  });

  test('非法 JSON 和无有效候选的响应报告 invalidResponse', () async {
    for (final payload in ['{"error":"$_key"', '{"choices":[]}', '{']) {
      dio.httpClientAdapter = _StubAdapter((_) => _jsonResponse(payload));
      await expectLater(
        client.chatCompletions(
          profile: _profile,
          apiKey: _key,
          messages: _messages,
        ),
        throwsA(_error(LlmErrorKind.invalidResponse)),
      );
    }
  });
}

Matcher _error(LlmErrorKind kind) => isA<LlmException>()
    .having((error) => error.kind, 'kind', kind)
    .having((error) => error.toString(), 'message', isNot(contains(_key)));

ResponseBody _jsonResponse(String body, [int status = 200]) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._respond);

  final ResponseBody Function(RequestOptions request) _respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => _respond(options);

  @override
  void close({bool force = false}) {}
}
