import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// 会话持久化域。
enum CredentialSessionDomain { unified, academic }

/// 单条持久会话状态。**不含密码**；`epoch` 是持久身份纪元，用于条件提交。
class CredentialSessionEnvelope {
  const CredentialSessionEnvelope({
    this.account,
    this.active = false,
    this.epoch = 0,
  });

  final String? account;
  final bool active;
  final int epoch;

  CredentialSessionEnvelope copyWith({
    String? account,
    bool clearAccount = false,
    bool? active,
    int? epoch,
  }) {
    return CredentialSessionEnvelope(
      account: clearAccount ? null : (account ?? this.account),
      active: active ?? this.active,
      epoch: epoch ?? this.epoch,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'active': active,
    'epoch': epoch,
  };

  static CredentialSessionEnvelope? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final epoch = decoded['epoch'];
      return CredentialSessionEnvelope(
        account: decoded['account']?.toString(),
        active: decoded['active'] == true,
        epoch: epoch is int ? epoch : 0,
      );
    } catch (_) {
      return null;
    }
  }
}

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

  // Session metadata: 单条 envelope（单 key 一次写入），避免 account/active
  // 两条 key 分开写时 logout 与 commit 交错写回旧身份。
  static const _keyZfSession = 'zjxu_zf_session_v2';
  static const _keyUaSession = 'zjxu_ua_session_v2';

  // 旧版多 key 仅用于一次性迁移读取，迁移后删除。
  static const _keyZfStudentIdLegacy = 'zjxu_zf_student_id';
  static const _keyZfSessionActiveLegacy = 'zjxu_zf_session_active';
  static const _keyUaAccountLegacy = 'zjxu_ua_account';
  static const _keyUaSessionActiveLegacy = 'zjxu_ua_session_active';

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

  // ── Session envelope（v2 单 key） ─────────────────────────────────────────

  /// 读取某域的 session envelope。损坏时 **fail closed** 为未激活（epoch 归零），
  /// 不猜测、不复活；旧版多 key 会在缺失 v2 key 时迁移一次。
  Future<CredentialSessionEnvelope> readSessionEnvelope(
    CredentialSessionDomain domain,
  ) async {
    final key = _sessionKey(domain);
    final raw = await _storage.read(key: key);
    if (raw != null) {
      return CredentialSessionEnvelope.tryParse(raw) ??
          const CredentialSessionEnvelope();
    }
    return _migrateLegacySession(domain);
  }

  /// 单 key 原子写入整个 envelope。凭据/密码不在此处，加密格式不受影响。
  Future<void> writeSessionEnvelope(
    CredentialSessionDomain domain,
    CredentialSessionEnvelope envelope,
  ) async {
    await _storage.write(
      key: _sessionKey(domain),
      value: jsonEncode(envelope.toJson()),
    );
  }

  String _sessionKey(CredentialSessionDomain domain) =>
      domain == CredentialSessionDomain.unified ? _keyUaSession : _keyZfSession;

  Future<CredentialSessionEnvelope> _migrateLegacySession(
    CredentialSessionDomain domain,
  ) async {
    final isUnified = domain == CredentialSessionDomain.unified;
    final accountKey = isUnified ? _keyUaAccountLegacy : _keyZfStudentIdLegacy;
    final activeKey = isUnified
        ? _keyUaSessionActiveLegacy
        : _keyZfSessionActiveLegacy;

    final account = await _storage.read(key: accountKey);
    final active = await _storage.read(key: activeKey);
    final hasLegacy = account != null || active != null;
    final envelope =
        (active == '1' && account != null && account.trim().isNotEmpty)
        ? CredentialSessionEnvelope(account: account, active: true)
        : const CredentialSessionEnvelope();
    if (hasLegacy) {
      await writeSessionEnvelope(domain, envelope);
      await _storage.delete(key: accountKey);
      await _storage.delete(key: activeKey);
    }
    return envelope;
  }

  // ── Zhengfang session persistence ──────────────────────────────────────────

  Future<String?> loadZhengfangSession() async {
    final envelope = await readSessionEnvelope(
      CredentialSessionDomain.academic,
    );
    return envelope.active ? envelope.account : null;
  }

  // ── Unified Auth session persistence ───────────────────────────────────────

  Future<String?> loadUnifiedAuthSession() async {
    final envelope = await readSessionEnvelope(CredentialSessionDomain.unified);
    return envelope.active ? envelope.account : null;
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
