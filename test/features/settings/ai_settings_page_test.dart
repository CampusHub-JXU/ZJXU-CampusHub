import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/ai/llm_client.dart';
import 'package:jxu_campus_hub/core/ai/llm_config_controller.dart';
import 'package:jxu_campus_hub/core/ai/llm_config_repository.dart';
import 'package:jxu_campus_hub/core/ai/llm_profile.dart';
import 'package:jxu_campus_hub/features/settings/ai_settings_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  late LlmConfigRepository repository;
  late Dio dio;
  late LlmClient client;
  late ResponseBody Function(RequestOptions request) respond;

  setUp(() async {
    await resetTestEnvironment();
    preferences = await SharedPreferences.getInstance();
    repository = LlmConfigRepository(
      preferences: preferences,
      secureStorage: const FlutterSecureStorage(),
    );

    respond = (_) =>
        _jsonResponse('{"choices":[{"message":{"content":"OK"}}]}');
    dio = Dio()..httpClientAdapter = _StubAdapter((req) => respond(req));
    client = LlmClient(dio: dio);
    addTearDown(() => dio.close(force: true));
  });

  LlmConfigController newController() {
    final controller = LlmConfigController(repository: repository);
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required LlmConfigController controller,
    Size size = const Size(420, 840),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: AiSettingsPage(controller: controller, client: client),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('自动初始化并展示默认 DeepSeek 配置及密钥状态', (tester) async {
    final controller = newController();
    await pumpPage(tester, controller: controller);

    expect(find.text('AI 模型与接口'), findsOneWidget);
    expect(find.text('DeepSeek 官方'), findsOneWidget);
    expect(find.text('deepseek-chat · 未配置密钥'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

    await controller.saveProfile(
      controller.activeProfile!,
      apiKey: 'test-token-ds-key',
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('deepseek-chat · 已配置密钥'), findsOneWidget);
  });

  testWidgets('点击整行切换当前激活配置', (tester) async {
    final controller = newController();
    await controller.init();
    final deepSeek = controller.activeProfile!;
    await controller.saveProfile(deepSeek, apiKey: 'test-token-ds');
    const custom = LlmProfile(
      id: 'magpie-gateway',
      name: 'Magpie 网关',
      preset: LlmProviderPreset.openaiCompatible,
      baseUrl: 'http://127.0.0.1:3425/v1',
      model: 'auto/gemini-4-hydrogen',
    );
    await controller.saveProfile(custom);

    await pumpPage(tester, controller: controller);

    expect(controller.activeProfileId, deepSeek.id);
    expect(find.text('deepseek-chat · 已配置密钥'), findsOneWidget);
    expect(find.text('auto/gemini-4-hydrogen · 未配置密钥'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai_profile_row_magpie-gateway')));
    await tester.pump();
    await tester.pump();

    expect(controller.activeProfileId, 'magpie-gateway');
    final radioIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('ai_profile_row_magpie-gateway')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
    );
    expect(radioIcon.icon, Icons.radio_button_checked);
  });

  testWidgets('主页面测试连接显示延迟成功结果与失败提示', (tester) async {
    final controller = newController();
    await controller.init();
    await controller.saveProfile(controller.activeProfile!, apiKey: 'sk-valid');

    await pumpPage(tester, controller: controller);

    await tester.tap(find.byKey(const Key('ai_test_connection_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('连接正常 · '), findsOneWidget);
    expect(find.textContaining('ms'), findsOneWidget);

    respond = (_) => _jsonResponse('{"error":"unauthorized"}', 401);
    await tester.tap(find.byKey(const Key('ai_test_connection_button')));
    await tester.pumpAndSettle();

    expect(find.text('AI 服务认证失败，请检查 API Key 和访问权限。'), findsOneWidget);
  });

  testWidgets('添加配置：预设切换、快捷芯片、非空校验、密钥显隐与温度滑条', (tester) async {
    final controller = newController();
    await pumpPage(tester, controller: controller);

    await tester.tap(find.byKey(const Key('ai_add_profile_button')));
    await tester.pumpAndSettle();

    expect(find.text('添加配置'), findsNWidgets(2));

    // 默认 DeepSeek 预设自动填充 Base URL 与 Model，并显示快捷芯片
    final baseUrlField = tester.widget<TextFormField>(
      find.byKey(const Key('ai_base_url_field')),
    );
    final modelField = tester.widget<TextFormField>(
      find.byKey(const Key('ai_model_field')),
    );
    expect(baseUrlField.controller?.text, 'https://api.deepseek.com/v1');
    expect(modelField.controller?.text, 'deepseek-chat');

    await tester.tap(find.byKey(const Key('ai_model_chip_deepseek-reasoner')));
    await tester.pump();
    expect(modelField.controller?.text, 'deepseek-reasoner');

    // 切换到 OpenAI 兼容清空默认 DeepSeek 值并隐藏快捷芯片
    await tester.tap(find.text('OpenAI 兼容'));
    await tester.pump();
    expect(baseUrlField.controller?.text, isEmpty);
    expect(modelField.controller?.text, isEmpty);
    expect(find.byKey(const Key('ai_model_chip_deepseek-chat')), findsNothing);

    // 非空校验拦截保存
    await tester.tap(find.byKey(const Key('ai_save_profile_button')));
    await tester.pump();
    expect(find.text('请输入配置名称'), findsOneWidget);
    expect(find.text('请输入 Base URL'), findsOneWidget);
    expect(find.text('请输入模型名称'), findsOneWidget);

    // 密钥遮罩默认开启，支持显隐切换
    TextField apiKeyInner() => tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('ai_api_key_field')),
        matching: find.byType(TextField),
      ),
    );
    expect(apiKeyInner().obscureText, isTrue);
    await tester.tap(find.byKey(const Key('ai_api_key_visibility_button')));
    await tester.pump();
    expect(apiKeyInner().obscureText, isFalse);

    // 填写 OpenAI 兼容配置并调整温度后保存
    await tester.enterText(find.byKey(const Key('ai_name_field')), 'AxonHub');
    await tester.enterText(
      find.byKey(const Key('ai_base_url_field')),
      'https://axon.example.com/v1',
    );
    await tester.enterText(find.byKey(const Key('ai_model_field')), 'gpt-4o');
    await tester.enterText(
      find.byKey(const Key('ai_api_key_field')),
      'test-token-axon',
    );

    final sliderFinder = find.byKey(const Key('ai_temperature_slider'));
    await tester.ensureVisible(sliderFinder);
    final slider = tester.widget<Slider>(sliderFinder);
    slider.onChanged!(1.2);
    await tester.pump();
    expect(find.text('1.2'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('ai_save_profile_button')));
    await tester.tap(find.byKey(const Key('ai_save_profile_button')));
    await tester.pumpAndSettle();

    expect(controller.profiles, hasLength(2));
    final saved = controller.profiles.last;
    expect(saved.name, 'AxonHub');
    expect(saved.preset, LlmProviderPreset.openaiCompatible);
    expect(saved.baseUrl, 'https://axon.example.com/v1');
    expect(saved.model, 'gpt-4o');
    expect(saved.temperature, 1.2);
    expect(await controller.readApiKey(saved.id), 'test-token-axon');
    expect(find.text('gpt-4o · 已配置密钥'), findsOneWidget);
  });

  testWidgets('编辑配置：留空密钥保留原 Key，弹层内测试连接可用', (tester) async {
    final controller = newController();
    await controller.init();
    final deepSeek = controller.activeProfile!;
    await controller.saveProfile(deepSeek, apiKey: 'test-token-original');

    await pumpPage(tester, controller: controller);

    await tester.tap(find.byKey(Key('ai_profile_menu_${deepSeek.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑配置'), findsOneWidget);
    expect(find.text('留空保持原密钥'), findsOneWidget);

    // 弹层内留空密钥测试连接时，自动读取已保存的原密钥
    String? sentAuthHeader;
    respond = (req) {
      sentAuthHeader = req.headers['authorization'] as String?;
      return _jsonResponse('{"choices":[{"message":{"content":"OK"}}]}');
    };
    await tester.ensureVisible(
      find.byKey(const Key('ai_sheet_test_connection_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_sheet_test_connection_button')));
    await tester.pumpAndSettle();
    expect(sentAuthHeader, 'Bearer test-token-original');
    expect(find.textContaining('连接正常 · '), findsOneWidget);

    // 修改名称后留空密钥保存，原密钥保持不变
    await tester.ensureVisible(find.byKey(const Key('ai_name_field')));
    await tester.enterText(
      find.byKey(const Key('ai_name_field')),
      'DeepSeek 推理',
    );
    await tester.ensureVisible(find.byKey(const Key('ai_save_profile_button')));
    await tester.tap(find.byKey(const Key('ai_save_profile_button')));
    await tester.pumpAndSettle();

    expect(controller.activeProfile?.name, 'DeepSeek 推理');
    expect(controller.activeApiKey, 'test-token-original');
    expect(await controller.readApiKey(deepSeek.id), 'test-token-original');
  });

  testWidgets('删除配置弹出确认框，确认后移除并展示空态', (tester) async {
    final controller = newController();
    await controller.init();
    final deepSeek = controller.activeProfile!;
    await controller.saveProfile(deepSeek, apiKey: 'test-token-delete');

    await pumpPage(tester, controller: controller);

    await tester.tap(find.byKey(Key('ai_profile_menu_${deepSeek.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除配置'), findsOneWidget);

    // 先点取消
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.profiles, hasLength(1));

    // 再次点删除并确认
    await tester.tap(find.byKey(Key('ai_profile_menu_${deepSeek.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(controller.profiles, isEmpty);
    expect(find.text('暂无 AI 配置'), findsOneWidget);
    expect(await controller.readApiKey(deepSeek.id), isNull);
  });

  testWidgets('360x640 + 1.5 倍字号下列表页与编辑弹层无溢出', (tester) async {
    final controller = newController();
    await pumpPage(
      tester,
      controller: controller,
      size: const Size(360, 640),
      textScale: 1.5,
    );

    await tester.tap(find.byKey(const Key('ai_add_profile_button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

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
