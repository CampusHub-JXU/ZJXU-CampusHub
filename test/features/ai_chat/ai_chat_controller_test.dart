import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/ai/llm_client.dart';
import 'package:jxu_campus_hub/core/ai/llm_config_controller.dart';
import 'package:jxu_campus_hub/core/ai/llm_config_repository.dart';
import 'package:jxu_campus_hub/core/ai/llm_profile.dart';
import 'package:jxu_campus_hub/app/ai_export_chat_adapter.dart';
import 'package:jxu_campus_hub/features/ai_chat/ai_chat_page.dart';
import 'package:jxu_campus_hub/features/ai_export/export_builder.dart';
import 'package:jxu_campus_hub/features/ai_export/export_controller.dart';
import 'package:jxu_campus_hub/features/ai_export/export_document.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';
import 'package:jxu_campus_hub/shared/ai_chat/ai_chat_context.dart';
import 'package:jxu_campus_hub/shared/ai_chat/ai_chat_controller.dart';
import 'package:jxu_campus_hub/shared/ai_chat/ai_chat_sheet.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/ai_export_fixtures.dart';
import '../../helpers/test_setup.dart';

class _FakeLlmClient extends LlmClient {
  _FakeLlmClient();

  final List<List<LlmMessage>> recordedRequests = [];
  final List<CancelToken?> recordedTokens = [];

  Stream<LlmStreamDelta> Function({
    required LlmProfile profile,
    required String apiKey,
    required List<LlmMessage> messages,
    CancelToken? cancelToken,
  })?
  onStream;

  @override
  Stream<LlmStreamDelta> streamChatCompletions({
    required LlmProfile profile,
    required String apiKey,
    required List<LlmMessage> messages,
    double? temperature,
    int? maxTokens,
    bool jsonMode = false,
    CancelToken? cancelToken,
  }) {
    recordedRequests.add(List.unmodifiable(messages));
    recordedTokens.add(cancelToken);
    if (onStream != null) {
      return onStream!(
        profile: profile,
        apiKey: apiKey,
        messages: messages,
        cancelToken: cancelToken,
      );
    }
    return Stream.fromIterable(const [
      LlmStreamDelta(reasoningDelta: '先梳理条件'),
      LlmStreamDelta(contentDelta: '你好，这是测试回复。', finishReason: 'stop'),
    ]);
  }
}

class _FakeIdentity extends ChangeNotifier {
  _FakeIdentity();

  String? academic = '20250001';
  String? unified = 'cas-1';

  ExportIdentity read() => ExportIdentity(academic: academic, unified: unified);
}

/// 测试用上下文提供者：内部挂真实 [AiExportController]，
/// `ensureSelectedReady` 不做联网补齐（与本地缓存就绪语义一致）。
class _TestChatContextProvider extends AiChatContextProvider {
  _TestChatContextProvider(this.exportController) {
    exportController.addListener(notifyListeners);
  }

  final AiExportController exportController;

  @override
  List<AiChatContextModule> get modules => [
    for (final m in exportController.availableModules)
      AiChatContextModule(
        id: m.key,
        label: m.label,
        selected: exportController.selected.contains(m),
        isReady: exportController.slotOf(m).data?.status.hasData ?? false,
        isLoading: exportController.slotOf(m).phase == ExportSlotPhase.loading,
        error: null,
      ),
  ];

  @override
  int get readyCount => exportController.selected
      .where((m) => exportController.slotOf(m).data?.status.hasData ?? false)
      .length;

  @override
  int get selectedCount => exportController.selected.length;

  @override
  bool get isBusy => false;

  @override
  Future<void> initialize() => exportController.initialize();

  @override
  void toggleModule(String id, bool selected) {
    for (final m in exportController.availableModules) {
      if (m.key == id) {
        if (exportController.selected.contains(m) != selected) {
          exportController.toggleModule(m);
        }
        return;
      }
    }
  }

  @override
  Future<void> ensureSelectedReady() async {}

  @override
  String buildContextText() => ExportBuilder.plainText(
    AiExportDocument(
      exportedAt: kExportNow,
      environment: kExportEnvironment,
      modules: [
        for (final m in exportController.buildDocument().modules)
          if (m.status.hasData) m,
      ],
    ),
  );

  @override
  void dispose() {
    exportController.removeListener(notifyListeners);
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LlmConfigController configController;
  late _FakeLlmClient fakeClient;

  Future<LlmConfigController> createConfig({bool withKey = true}) async {
    if (!withKey) {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    }
    final prefs = await SharedPreferences.getInstance();
    final repo = LlmConfigRepository(
      preferences: prefs,
      secureStorage: const FlutterSecureStorage(),
    );
    final controller = LlmConfigController(repository: repo);
    addTearDown(controller.dispose);
    await controller.init();
    if (withKey) {
      await controller.saveProfile(
        controller.activeProfile!,
        apiKey: 'test-secret-key',
      );
    }
    return controller;
  }

  setUp(() async {
    await resetTestEnvironment();
    fakeClient = _FakeLlmClient();
    configController = await createConfig(withKey: true);
  });

  group('AiChatController 单元测试', () {
    test('流式接收思考过程与正文，结束后更新状态', () async {
      final streamController = StreamController<LlmStreamDelta>();
      fakeClient.onStream = ({
        required profile,
        required apiKey,
        required messages,
        cancelToken,
      }) => streamController.stream;

      final controller = AiChatController(
        configController: configController,
        llmClient: fakeClient,
      );
      addTearDown(controller.dispose);

      final sendFuture = controller.sendMessage('帮我看看成绩');
      expect(controller.isGenerating, isTrue);
      expect(controller.messages, hasLength(2));
      expect(controller.messages.first.role, AiChatRole.user);
      expect(controller.messages.last.role, AiChatRole.assistant);
      expect(controller.messages.last.isStreaming, isTrue);

      streamController.add(const LlmStreamDelta(reasoningDelta: '正在核对绩点'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages.last.reasoningContent, '正在核对绩点');

      streamController.add(const LlmStreamDelta(contentDelta: '你的加权绩点为 '));
      streamController.add(
        const LlmStreamDelta(contentDelta: '3.8。', finishReason: 'stop'),
      );
      await streamController.close();
      await sendFuture;

      expect(controller.isGenerating, isFalse);
      expect(controller.messages.last.isStreaming, isFalse);
      expect(controller.messages.last.content, '你的加权绩点为 3.8。');
      expect(controller.messages.last.reasoningContent, '正在核对绩点');
      expect(controller.messages.last.errorMessage, isNull);
    });

    test('未配置 API Key 时不发网络请求并给出配置提示', () async {
      final unconfigured = await createConfig(withKey: false);
      final controller = AiChatController(
        configController: unconfigured,
        llmClient: fakeClient,
      );
      addTearDown(controller.dispose);

      await controller.sendMessage('你好');

      expect(fakeClient.recordedRequests, isEmpty);
      expect(controller.isGenerating, isFalse);
      expect(controller.messages, hasLength(2));
      expect(
        controller.messages.last.errorMessage,
        LlmErrorKind.notConfigured.message,
      );
    });

    test('stopGeneration 通过 CancelToken 中断流式输出并保留已生成内容', () async {
      final streamController = StreamController<LlmStreamDelta>();
      addTearDown(streamController.close);
      fakeClient.onStream = ({
        required profile,
        required apiKey,
        required messages,
        cancelToken,
      }) => streamController.stream;

      final controller = AiChatController(
        configController: configController,
        llmClient: fakeClient,
      );
      addTearDown(controller.dispose);

      final sendFuture = controller.sendMessage('详细分析一下');
      streamController.add(const LlmStreamDelta(contentDelta: '第一部分内容'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages.last.content, '第一部分内容');

      controller.stopGeneration();
      expect(controller.isGenerating, isFalse);
      expect(controller.messages.last.isStreaming, isFalse);
      expect(controller.messages.last.content, '第一部分内容');
      expect(controller.messages.last.errorMessage, isNull);
      expect(fakeClient.recordedTokens.single?.isCancelled, isTrue);

      // 停止后迟到的增量不再改写消息
      streamController.add(const LlmStreamDelta(contentDelta: '迟到内容'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages.last.content, '第一部分内容');
      await streamController.close();
      await sendFuture;
    });

    test('挂载 AiChatContextProvider：仅附带已勾选且已就绪模块，未变化不重复刷屏，变化后更新', () async {
      final identity = _FakeIdentity();
      addTearDown(identity.dispose);
      ExportModuleData? examsLocal;
      final provider = _TestChatContextProvider(
        AiExportController(
          sources: [
            ExportModuleSource(
              module: ExportModule.grades,
              readLocal: () async => gradesData(),
              fetch: ({required force}) async => ExportFetched(gradesData()),
            ),
            ExportModuleSource(
              module: ExportModule.exams,
              readLocal: () async => examsLocal,
              fetch: ({required force}) async => ExportFetched(examsData()),
            ),
            ExportModuleSource(
              module: ExportModule.schedule,
              readLocal: () async => scheduleData(),
              fetch: ({required force}) async => ExportFetched(scheduleData()),
            ),
          ],
          identity: identity.read,
          identityChanges: identity,
          clock: () => kExportNow,
          environment: (_) => kExportEnvironment,
        ),
      );
      addTearDown(provider.dispose);
      final exportController = provider.exportController;
      addTearDown(exportController.dispose);

      final chatController = AiChatController(
        configController: configController,
        llmClient: fakeClient,
        contextProvider: provider,
        clock: () => kExportNow,
      );
      addTearDown(chatController.dispose);
      await chatController.initialize();

      // 取消勾选 schedule，保留 grades(已就绪) 和 exams(未获取)
      exportController.toggleModule(ExportModule.schedule);

      // 第 1 轮：仅附带 grades，不包含未获取的 exams 或未勾选的 schedule
      await chatController.sendMessage('我的成绩怎么样？');
      expect(chatController.contextSyncCount, 1);
      final req1 = fakeClient.recordedRequests[0];
      expect(req1.where((m) => m.role == 'system'), hasLength(1));
      expect(req1.first.content, contains('高等数学A'));
      expect(req1.first.content, isNot(contains('[考试安排]')));
      expect(req1.first.content, isNot(contains('[课表]')));

      // 第 2 轮：上下文未变化，不重算上下文，不追加重复 system 消息
      await chatController.sendMessage('具体哪门最高？');
      expect(chatController.contextSyncCount, 1);
      final req2 = fakeClient.recordedRequests[1];
      expect(req2.where((m) => m.role == 'system'), hasLength(1));
      expect(req2.first.content, req1.first.content);
      expect(req2.map((m) => m.role).toList(), [
        'system',
        'user',
        'assistant',
        'user',
      ]);

      // 第 3 轮：获取了 exams 并重新勾选 schedule，上下文发生变化，重新同步一次
      await exportController.fetch(ExportModule.exams);
      exportController.toggleModule(ExportModule.schedule);
      await chatController.sendMessage('考试和课表呢？');
      expect(chatController.contextSyncCount, 2);
      final req3 = fakeClient.recordedRequests[2];
      expect(req3.where((m) => m.role == 'system'), hasLength(1));
      expect(req3.first.content, contains('[考试安排]'));
      expect(req3.first.content, contains('线性代数'));
      expect(req3.first.content, contains('[课表]'));
    });

    test('支持 fixedContext 注入与失败重试', () async {
      var attempt = 0;
      fakeClient.onStream =
          ({
            required profile,
            required apiKey,
            required messages,
            cancelToken,
          }) async* {
            attempt++;
            if (attempt == 1) {
              throw const LlmException(LlmErrorKind.rateLimit);
            }
            yield const LlmStreamDelta(
              contentDelta: '重试成功：选 B。',
              finishReason: 'stop',
            );
          };

      final controller = AiChatController(
        configController: configController,
        llmClient: fakeClient,
        fixedContext: '题干：2+2=?\n参考答案：B',
      );
      addTearDown(controller.dispose);

      await controller.sendMessage('为什么选 B？');
      expect(controller.messages.last.hasError, isTrue);
      expect(
        controller.messages.last.errorMessage,
        LlmErrorKind.rateLimit.message,
      );
      expect(
        fakeClient.recordedRequests.single.first.content,
        contains('2+2=?'),
      );

      await controller.retryLast();
      expect(controller.messages.last.hasError, isFalse);
      expect(controller.messages.last.content, '重试成功：选 B。');
    });
  });

  group('AiChatPage 与 AiChatSheet Widget 测试', () {
    List<ExportModuleSource> sampleSources() => [
      ExportModuleSource(
        module: ExportModule.grades,
        readLocal: () async => gradesData(),
        fetch: ({required force}) async => ExportFetched(gradesData()),
      ),
      ExportModuleSource(
        module: ExportModule.exams,
        fetch: ({required force}) async => ExportFetched(examsData()),
      ),
    ];

    AiExportChatContextProvider sampleProvider() {
      final identity = _FakeIdentity();
      addTearDown(identity.dispose);
      return AiExportChatContextProvider(
        sources: sampleSources,
        identity: identity.read,
        identityChanges: identity,
        clock: () => kExportNow,
        environment: (_) => kExportEnvironment,
      );
    }

    testWidgets('未配置 Key 时显示紧凑提示条与入口，模型芯片可跳配置', (tester) async {
      final unconfigured = await createConfig(withKey: false);
      var openedSettings = 0;
      var openedExport = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: AiChatPage(
            contextProvider: sampleProvider(),
            configController: unconfigured,
            llmClient: fakeClient,
            onOpenSettings: () => openedSettings++,
            onOpenExport: () => openedExport++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.text('deepseek-chat'), findsOneWidget);
      expect(find.text('未配置 API Key'), findsOneWidget);
      expect(find.text('总结本学期成绩与绩点'), findsOneWidget);
      expect(find.text('查看本周剩余课程'), findsOneWidget);
      expect(find.text('梳理近期待办与考试'), findsOneWidget);

      await tester.tap(find.text('去配置'));
      await tester.pump();
      expect(openedSettings, 1);

      await tester.tap(find.byKey(const Key('ai_chat_model_chip')));
      await tester.pump();
      expect(openedSettings, 2);

      await tester.tap(find.text('导出给外部 AI'));
      await tester.pump();
      expect(openedExport, 1);

      await tester.tap(find.byKey(const Key('ai_chat_export_button')));
      await tester.pump();
      expect(openedExport, 2);
    });

    testWidgets('快捷提问发送、Markdown 渲染、思考过程折叠与复制回复', (tester) async {
      final clipCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          clipCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      fakeClient.onStream =
          ({
            required profile,
            required apiKey,
            required messages,
            cancelToken,
          }) async* {
            yield const LlmStreamDelta(reasoningDelta: '第一步：核对成绩明细。');
            yield const LlmStreamDelta(
              contentDelta: '# 成绩汇总\n\n**加权绩点** 为 `3.85`。\n- 高等数学A\n1. 大学英语\n\n```dart\nprint(3.85);\n```',
              finishReason: 'stop',
            );
          };

      await tester.pumpWidget(
        MaterialApp(
          home: AiChatPage(
            contextProvider: sampleProvider(),
            configController: configController,
            llmClient: fakeClient,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('ai_chat_quick_prompt_0')));
      await tester.pump();
      await tester.pump();

      // 思考过程默认折叠
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.text('第一步：核对成绩明细。'), findsNothing);

      await tester.tap(find.text('思考过程'));
      await tester.pump();
      await tester.pump();
      expect(find.text('第一步：核对成绩明细。'), findsOneWidget);

      // Markdown 内容渲染（无原始 ** / # / ``` 符号）
      expect(find.textContaining('成绩汇总'), findsOneWidget);
      expect(find.textContaining('print(3.85);'), findsOneWidget);

      // 复制回复按钮
      await tester.tap(find.text('复制').last);
      await tester.pump();
      final copied = clipCalls
          .where((c) => c.method == 'Clipboard.setData')
          .single;
      expect((copied.arguments as Map)['text'], contains('成绩汇总'));
      expect(find.text('已复制回复'), findsOneWidget);
    });

    testWidgets('可折叠学业上下文芯片栏在 360x640 + 1.5 倍字号下无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: AiChatPage(
              contextProvider: sampleProvider(),
              configController: configController,
              llmClient: fakeClient,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('ai_chat_context_toggle')));
      await tester.pump();
      await tester.pump();

      expect(find.text('成绩'), findsOneWidget);
      expect(find.text('考试安排'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AiChatSheet.show 支持上下文预览与空态一键提问', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => AiChatSheet.show(
                    context,
                    title: '题目答疑',
                    initialContext: '题目：操作系统中什么是死锁？',
                    initialPrompt: '请结合本题解析死锁四个必要条件',
                    configController: configController,
                    llmClient: fakeClient,
                  ),
                  child: const Text('打开面板'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();

      expect(find.text('题目答疑'), findsOneWidget);
      expect(find.text('已附带上下文'), findsOneWidget);
      expect(find.text('题目：操作系统中什么是死锁？'), findsNothing);

      // 展开预览上下文
      await tester.tap(find.byKey(const Key('ai_chat_sheet_context_toggle')));
      await tester.pumpAndSettle();
      expect(find.text('题目：操作系统中什么是死锁？'), findsOneWidget);

      // 一键提问按钮
      await tester.tap(find.byKey(const Key('ai_chat_sheet_initial_prompt')));
      await tester.pump();
      await tester.pump();

      expect(fakeClient.recordedRequests, hasLength(1));
      expect(
        fakeClient.recordedRequests.single.first.content,
        contains('操作系统中什么是死锁'),
      );
      expect(find.text('你好，这是测试回复。'), findsOneWidget);
    });
  });
}
