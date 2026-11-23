import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/ai/llm_config_controller.dart';
import 'package:jxu_campus_hub/core/ai/llm_config_repository.dart';
import 'package:jxu_campus_hub/core/ai/llm_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  late LlmConfigRepository repository;
  late LlmConfigController controller;
  const storage = FlutterSecureStorage();
  const customProfile = LlmProfile(
    id: 'custom',
    name: '自定义网关',
    preset: LlmProviderPreset.openaiCompatible,
    baseUrl: 'https://gateway.example/v1',
    model: 'custom-model',
    maxTokens: 256,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    repository = LlmConfigRepository(
      preferences: preferences,
      secureStorage: storage,
    );
    controller = LlmConfigController(repository: repository);
    addTearDown(controller.dispose);
  });

  test('首次初始化创建默认 DeepSeek 配置，填入 Key 后可用', () async {
    await Future.wait([controller.init(), controller.init()]);

    expect(controller.profiles, hasLength(1));
    final profile = controller.activeProfile!;
    expect(profile.id, 'default-deepseek');
    expect(profile.name, 'DeepSeek 官方');
    expect(profile.preset, LlmProviderPreset.deepseek);
    expect(profile.baseUrl, profile.preset.defaultBaseUrl);
    expect(profile.model, profile.preset.defaultModel);
    expect(profile.preset.commonModels, ['deepseek-chat', 'deepseek-reasoner']);
    expect(profile.temperature, 0.7);
    expect(controller.activeApiKey, isEmpty);
    expect(controller.isConfigured, isFalse);
    expect(await storage.readAll(), isEmpty);

    await controller.saveProfile(profile, apiKey: '  deepseek-test-key  ');
    expect(controller.activeApiKey, 'deepseek-test-key');
    expect(controller.isConfigured, isTrue);
  });

  test('切换和重载 Profile 时隔离 Key，偏好存储只含元数据', () async {
    await controller.init();
    final deepSeek = controller.activeProfile!;
    final observed = <(String?, String)>[];
    controller.addListener(
      () => observed.add((controller.activeProfileId, controller.activeApiKey)),
    );

    await Future.wait([
      controller.saveProfile(deepSeek, apiKey: 'deepseek-test-key'),
      controller.saveProfile(customProfile, apiKey: 'custom-test-key'),
      controller.setActiveProfile(customProfile.id),
    ]);
    expect(controller.activeProfile?.model, customProfile.model);
    expect(controller.activeApiKey, 'custom-test-key');
    expect(await controller.readApiKey(deepSeek.id), 'deepseek-test-key');
    expect(observed, [
      (deepSeek.id, 'deepseek-test-key'),
      (deepSeek.id, 'deepseek-test-key'),
      (customProfile.id, 'custom-test-key'),
    ]);

    final reloaded = LlmConfigController(repository: repository);
    addTearDown(reloaded.dispose);
    await reloaded.init();
    expect(reloaded.activeProfileId, customProfile.id);
    expect(reloaded.activeApiKey, 'custom-test-key');
    await reloaded.setActiveProfile(deepSeek.id);
    expect(reloaded.activeApiKey, 'deepseek-test-key');

    final preferencesJson = jsonEncode({
      for (final key in preferences.getKeys()) key: preferences.get(key),
    });
    expect(preferences.getKeys(), everyElement(startsWith('jxu_llm_')));
    expect(preferencesJson, isNot(contains('test-key')));
    expect(preferencesJson, isNot(contains('apiKey')));
    expect(
      (await storage.readAll()).values,
      unorderedEquals(['deepseek-test-key', 'custom-test-key']),
    );
  });

  test('编辑保留原 Key，空白 Key 和删除配置会清除安全存储', () async {
    await controller.init();
    final defaultId = controller.activeProfileId!;
    await controller.saveProfile(customProfile, apiKey: 'custom-test-key');
    await controller.setActiveProfile(customProfile.id);
    await controller.saveProfile(customProfile.copyWith(name: '新名称'));

    expect(controller.activeProfile?.name, '新名称');
    expect(controller.activeApiKey, 'custom-test-key');
    await controller.saveProfile(customProfile, apiKey: '  ');
    expect(controller.isConfigured, isFalse);
    expect(await controller.readApiKey(customProfile.id), isNull);

    await controller.saveProfile(customProfile, apiKey: 'replacement-key');
    await controller.deleteProfile(customProfile.id);
    expect(controller.activeProfileId, defaultId);
    expect(controller.activeApiKey, isEmpty);
    expect(await storage.readAll(), isEmpty);

    await controller.deleteProfile(defaultId);
    final reloaded = LlmConfigController(repository: repository);
    addTearDown(reloaded.dispose);
    await reloaded.init();
    expect(reloaded.profiles, isEmpty);
    expect(reloaded.activeProfile, isNull);
    expect(reloaded.isConfigured, isFalse);
  });

  test('Profile JSON 往返保留配置字段，支持清除 maxTokens', () {
    final json = customProfile.toJson();
    expect(json, isNot(contains('apiKey')));
    expect(LlmProfile.fromJson(json).toJson(), json);
    expect(customProfile.copyWith(clearMaxTokens: true).maxTokens, isNull);
    expect(customProfile.maxTokens, 256);
  });

  test('配置保存失败后恢复原 Key，下一次保存可正常执行', () async {
    final failingRepository = _FailingRepository(
      preferences: preferences,
      secureStorage: storage,
    );
    final subject = LlmConfigController(repository: failingRepository);
    addTearDown(subject.dispose);
    await subject.init();
    final profile = subject.activeProfile!;
    await subject.saveProfile(profile, apiKey: 'original-key');

    failingRepository.fail = true;
    await expectLater(
      subject.saveProfile(profile.copyWith(name: '新名称'), apiKey: 'next-key'),
      throwsStateError,
    );
    expect(subject.activeProfile?.name, profile.name);
    expect(subject.activeApiKey, 'original-key');
    expect(await subject.readApiKey(profile.id), 'original-key');

    failingRepository.fail = false;
    await subject.saveProfile(
      profile.copyWith(name: '新名称'),
      apiKey: 'next-key',
    );
    expect(subject.activeProfile?.name, '新名称');
    expect(await subject.readApiKey(profile.id), 'next-key');
  });
}

class _FailingRepository extends LlmConfigRepository {
  _FailingRepository({
    required super.preferences,
    required super.secureStorage,
  });

  bool fail = false;

  @override
  Future<void> saveConfiguration({
    required List<LlmProfile> profiles,
    required String? activeProfileId,
  }) async {
    if (fail) throw StateError('模拟偏好存储写入失败');
    await super.saveConfiguration(
      profiles: profiles,
      activeProfileId: activeProfileId,
    );
  }
}
