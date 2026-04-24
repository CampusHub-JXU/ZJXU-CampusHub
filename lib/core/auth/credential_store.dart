import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

class CredentialStore {
  CredentialStore._();
  static final CredentialStore instance = CredentialStore._();

  static final _storage = FlutterSecureStorage();
  static const _keyUsername = 'zjxu_username';
  static const _keyPassword = 'zjxu_password';
  static const _keyUnifiedUsername = 'zjxu_unified_username';
  static const _keyUnifiedPassword = 'zjxu_unified_password';
  static const _keyCredentialEncryptionKey = 'zjxu_credential_encryption_key';
  static const _encryptedValuePrefix = 'enc:';

  // Session metadata keys
  static const _keyZfStudentId = 'zjxu_zf_student_id';
  static const _keyZfSessionActive = 'zjxu_zf_session_active';
  static const _keyUaAccount = 'zjxu_ua_account';
  static const _keyUaSessionActive = 'zjxu_ua_session_active';

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

  // ── Zhengfang session persistence ──────────────────────────────────────────

  Future<void> saveZhengfangSession(String studentId) async {
    await _storage.write(key: _keyZfStudentId, value: studentId);
    await _storage.write(key: _keyZfSessionActive, value: '1');
  }

  Future<String?> loadZhengfangSession() async {
    final active = await _storage.read(key: _keyZfSessionActive);
    if (active != '1') return null;
    return _storage.read(key: _keyZfStudentId);
  }

  Future<void> clearZhengfangSession() async {
    await _storage.delete(key: _keyZfStudentId);
    await _storage.delete(key: _keyZfSessionActive);
  }

  // ── Unified Auth session persistence ───────────────────────────────────────

  Future<void> saveUnifiedAuthSession(String account) async {
    await _storage.write(key: _keyUaAccount, value: account);
    await _storage.write(key: _keyUaSessionActive, value: '1');
  }

  Future<String?> loadUnifiedAuthSession() async {
    final active = await _storage.read(key: _keyUaSessionActive);
    if (active != '1') return null;
    return _storage.read(key: _keyUaAccount);
  }

  Future<void> clearUnifiedAuthSession() async {
    await _storage.delete(key: _keyUaAccount);
    await _storage.delete(key: _keyUaSessionActive);
  }

  Future<void> _writePair(
    String usernameKey,
    String username,
    String passwordKey,
    String password,
  ) async {
    final encryptedUsername = await _encryptValue(username);
    final encryptedPassword = await _encryptValue(password);
    await _storage.write(key: usernameKey, value: encryptedUsername);
    await _storage.write(key: passwordKey, value: encryptedPassword);
  }

  Future<(String, String)?> _readPair(
    String usernameKey,
    String passwordKey,
  ) async {
    final storedUsername = await _storage.read(key: usernameKey);
    final storedPassword = await _storage.read(key: passwordKey);
    if (storedUsername == null || storedPassword == null) return null;

    final username = await _decryptValue(storedUsername);
    final password = await _decryptValue(storedPassword);

    if (!_isEncryptedValue(storedUsername) ||
        !_isEncryptedValue(storedPassword)) {
      await _writePair(usernameKey, username, passwordKey, password);
    }

    return (username, password);
  }

  Future<void> _clearPair(String usernameKey, String passwordKey) async {
    await _storage.delete(key: usernameKey);
    await _storage.delete(key: passwordKey);
  }

  Future<String> _encryptValue(String value) async {
    final key = await _getOrCreateEncryptionKey();
    final iv = _randomBytes(16);
    final input = Uint8List.fromList(utf8.encode(value));
    final padded = _pkcs7Pad(input, 16);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    final output = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, output, offset);
    }
    return '$_encryptedValuePrefix${base64.encode(iv)}:${base64.encode(output)}';
  }

  Future<String> _decryptValue(String value) async {
    if (!_isEncryptedValue(value)) {
      return value;
    }

    final payload = value.substring(_encryptedValuePrefix.length);
    final separator = payload.indexOf(':');
    if (separator <= 0 || separator >= payload.length - 1) {
      throw const FormatException('凭证密文格式无效');
    }

    final iv = Uint8List.fromList(
      base64.decode(payload.substring(0, separator)),
    );
    final ciphertext = Uint8List.fromList(
      base64.decode(payload.substring(separator + 1)),
    );
    final key = await _getOrCreateEncryptionKey();
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final output = Uint8List(ciphertext.length);
    for (var offset = 0; offset < ciphertext.length; offset += 16) {
      cipher.processBlock(ciphertext, offset, output, offset);
    }
    return utf8.decode(_pkcs7Unpad(output));
  }

  Future<Uint8List> _getOrCreateEncryptionKey() async {
    final existingKey = await _storage.read(key: _keyCredentialEncryptionKey);
    if (existingKey != null) {
      return Uint8List.fromList(base64.decode(existingKey));
    }

    final key = _randomBytes(16);
    await _storage.write(
      key: _keyCredentialEncryptionKey,
      value: base64.encode(key),
    );
    return key;
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  bool _isEncryptedValue(String value) {
    return value.startsWith(_encryptedValuePrefix);
  }

  Uint8List _pkcs7Pad(Uint8List input, int blockSize) {
    final padding = blockSize - (input.length % blockSize);
    return Uint8List.fromList([
      ...input,
      ...List<int>.filled(padding, padding),
    ]);
  }

  Uint8List _pkcs7Unpad(Uint8List input) {
    if (input.isEmpty) return input;
    final padding = input.last;
    if (padding <= 0 || padding > 16 || padding > input.length) {
      throw const FormatException('凭证解密结果无效');
    }
    return Uint8List.sublistView(input, 0, input.length - padding);
  }
}
