import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CredentialStore {
  CredentialStore._();
  static final CredentialStore instance = CredentialStore._();

  static const _storage = FlutterSecureStorage();
  static const _keyUsername = 'zjxu_username';
  static const _keyPassword = 'zjxu_password';
  static const _keyUnifiedUsername = 'zjxu_unified_username';
  static const _keyUnifiedPassword = 'zjxu_unified_password';

  Future<void> saveCredentials(String username, String password) async {
    await _writePair(_keyUsername, username, _keyPassword, password);
  }

  Future<(String, String)?> loadCredentials() async {
    return _readPair(_keyUsername, _keyPassword);
  }

  Future<void> clearCredentials() async {
    await _clearPair(_keyUsername, _keyPassword);
  }

  Future<void> saveUnifiedAuthCredentials(
    String username,
    String password,
  ) async {
    await _writePair(
      _keyUnifiedUsername,
      username,
      _keyUnifiedPassword,
      password,
    );
  }

  Future<(String, String)?> loadUnifiedAuthCredentials() async {
    return _readPair(_keyUnifiedUsername, _keyUnifiedPassword);
  }

  Future<void> clearUnifiedAuthCredentials() async {
    await _clearPair(_keyUnifiedUsername, _keyUnifiedPassword);
  }

  Future<void> _writePair(
    String usernameKey,
    String username,
    String passwordKey,
    String password,
  ) async {
    await _storage.write(key: usernameKey, value: username);
    await _storage.write(key: passwordKey, value: password);
  }

  Future<(String, String)?> _readPair(
    String usernameKey,
    String passwordKey,
  ) async {
    final username = await _storage.read(key: usernameKey);
    final password = await _storage.read(key: passwordKey);
    if (username == null || password == null) return null;
    return (username, password);
  }

  Future<void> _clearPair(String usernameKey, String passwordKey) async {
    await _storage.delete(key: usernameKey);
    await _storage.delete(key: passwordKey);
  }
}
