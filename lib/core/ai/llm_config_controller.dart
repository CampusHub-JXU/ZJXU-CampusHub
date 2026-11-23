import 'package:flutter/foundation.dart';

import 'llm_config_repository.dart';
import 'llm_profile.dart';

class LlmConfigController extends ChangeNotifier {
  LlmConfigController({LlmConfigRepository? repository})
    : _repository = repository ?? LlmConfigRepository();

  static final instance = LlmConfigController();

  static const _defaultProfile = LlmProfile(
    id: 'default-deepseek',
    name: 'DeepSeek 官方',
    preset: LlmProviderPreset.deepseek,
    baseUrl: 'https://api.deepseek.com/v1',
    model: 'deepseek-chat',
  );

  final LlmConfigRepository _repository;
  Future<void> _pending = Future<void>.value();
  bool _initialized = false;
  List<LlmProfile> _profiles = const [];
  String? _activeProfileId;
  String _activeApiKey = '';

  List<LlmProfile> get profiles => _profiles;
  String? get activeProfileId => _activeProfileId;
  LlmProfile? get activeProfile =>
      _profiles.where((profile) => profile.id == _activeProfileId).firstOrNull;
  String get activeApiKey => _activeApiKey;
  bool get isConfigured =>
      activeProfile != null && activeApiKey.trim().isNotEmpty;

  Future<void> init() => _serialize(_initialize);

  /// Omitting [apiKey] retains the stored key. An empty value clears it.
  Future<void> saveProfile(LlmProfile profile, {String? apiKey}) =>
      _serialize(() async {
        await _initialize();
        final profiles = _profiles.toList();
        final index = profiles.indexWhere((item) => item.id == profile.id);
        if (index == -1) {
          profiles.add(profile);
        } else {
          profiles[index] = profile;
        }

        final id = _activeProfileId ?? profile.id;
        final key = apiKey?.trim();
        final activeKey = id == profile.id && key != null ? key : _activeApiKey;
        await _save(
          profiles,
          id,
          keyChange: key == null ? null : (id: profile.id, value: key),
        );
        _updateState(profiles, id, activeKey);
      });

  Future<void> setActiveProfile(String id) => _serialize(() async {
    await _initialize();
    if (!_profiles.any((profile) => profile.id == id)) {
      throw ArgumentError('找不到要启用的 AI 服务配置');
    }
    if (id == _activeProfileId) return;

    final key = await _repository.readApiKey(id) ?? '';
    await _save(_profiles, id);
    _updateState(_profiles, id, key);
  });

  Future<void> deleteProfile(String id) => _serialize(() async {
    await _initialize();
    final profiles = _profiles.where((profile) => profile.id != id).toList();
    if (profiles.length == _profiles.length) return;

    final nextId = id == _activeProfileId
        ? profiles.firstOrNull?.id
        : _activeProfileId;
    final key = nextId == _activeProfileId
        ? _activeApiKey
        : await _readActiveKey(nextId);
    await _save(profiles, nextId, keyChange: (id: id, value: null));
    _updateState(profiles, nextId, key);
  });

  Future<String?> readApiKey(String profileId) => _serialize(() async {
    await _initialize();
    if (!_profiles.any((profile) => profile.id == profileId)) return null;
    return _repository.readApiKey(profileId);
  });

  Future<void> _initialize() async {
    if (_initialized) return;

    final stored = await _repository.loadConfiguration();
    final profiles = stored?.profiles ?? const [_defaultProfile];
    final storedId = stored?.activeProfileId;
    final id = profiles.any((profile) => profile.id == storedId)
        ? storedId
        : profiles.firstOrNull?.id;
    final key = await _readActiveKey(id);
    if (stored == null || storedId != id) await _save(profiles, id);
    _initialized = true;
    _updateState(profiles, id, key);
  }

  Future<String> _readActiveKey(String? id) async =>
      id == null ? '' : await _repository.readApiKey(id) ?? '';

  Future<void> _save(
    List<LlmProfile> profiles,
    String? activeId, {
    ({String id, String? value})? keyChange,
  }) async {
    // Restore the old key if the metadata write fails after a key change.
    final previousKey = keyChange == null
        ? null
        : await _repository.readApiKey(keyChange.id);
    if (keyChange != null) {
      await _repository.writeApiKey(keyChange.id, keyChange.value);
    }
    try {
      await _repository.saveConfiguration(
        profiles: profiles,
        activeProfileId: activeId,
      );
    } catch (_) {
      if (keyChange != null) {
        await _repository.writeApiKey(keyChange.id, previousKey);
      }
      rethrow;
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  void _updateState(List<LlmProfile> profiles, String? id, String apiKey) {
    _profiles = List.unmodifiable(profiles);
    _activeProfileId = id;
    _activeApiKey = apiKey;
    notifyListeners();
  }
}
