import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm_profile.dart';

class LlmConfigRepository {
  LlmConfigRepository({
    this._preferences,
    this._secureStorage = const FlutterSecureStorage(),
  });

  static const _configKey = 'jxu_llm_config';
  static const _apiKeyPrefix = 'jxu_llm_api_key_';

  final SharedPreferences? _preferences;
  final FlutterSecureStorage _secureStorage;

  Future<({List<LlmProfile> profiles, String? activeProfileId})?>
  loadConfiguration() async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    final raw = preferences.getString(_configKey);
    if (raw == null) return null;

    final config = jsonDecode(raw) as Map<String, dynamic>;
    final profiles = (config['profiles'] as List<dynamic>)
        .map((item) => LlmProfile.fromJson(item as Map<String, dynamic>))
        .toList();
    return (
      profiles: profiles,
      activeProfileId: config['activeProfileId'] as String?,
    );
  }

  Future<void> saveConfiguration({
    required List<LlmProfile> profiles,
    required String? activeProfileId,
  }) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    final encoded = jsonEncode({
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
      'activeProfileId': activeProfileId,
    });
    try {
      if (!await preferences.setString(_configKey, encoded)) {
        throw StateError('无法保存 AI 服务配置');
      }
    } catch (_) {
      await preferences.reload();
      rethrow;
    }
  }

  Future<String?> readApiKey(String profileId) =>
      _secureStorage.read(key: '$_apiKeyPrefix$profileId');

  Future<void> writeApiKey(String profileId, String? apiKey) {
    final key = '$_apiKeyPrefix$profileId';
    if (apiKey == null || apiKey.isEmpty) {
      return _secureStorage.delete(key: key);
    }
    return _secureStorage.write(key: key, value: apiKey);
  }
}
