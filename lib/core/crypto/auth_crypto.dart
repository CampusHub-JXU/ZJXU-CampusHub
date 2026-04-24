import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'auth_crypto_config.dart';

/// 统一认证密码加密工具
///
/// 使用 AES-128-CBC 模式加密密码，PKCS7 填充。
/// 与前端 JavaScript main.js 中的加密逻辑保持一致。
class AuthCrypto {
  AuthCrypto._();
  static final AuthCrypto instance = AuthCrypto._();

  /// AES-128-CBC 加密密码
  ///
  /// 使用 [AuthCryptoConfig] 中配置的密钥和 IV，
  /// 返回十六进制字符串 (大写)。
  ///
  /// 如果密钥无效，抛出异常并中止登录。
  String encryptPassword(String password) {
    final config = AuthCryptoConfig.instance;
    if (!config.isValid()) {
      throw StateError('统一认证密码加密配置无效');
    }

    final keyBytes = Uint8List.fromList(utf8.encode(config.aesKey));
    final ivBytes = Uint8List.fromList(utf8.encode(config.aesIv));
    final input = Uint8List.fromList(utf8.encode(password));

    final paddedInput = _pkcs7Pad(input, AuthCryptoConfig.aesBlockSize);

    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(keyBytes), ivBytes));

    final output = Uint8List(paddedInput.length);
    for (
      var offset = 0;
      offset < paddedInput.length;
      offset += AuthCryptoConfig.aesBlockSize
    ) {
      cipher.processBlock(paddedInput, offset, output, offset);
    }

    final buffer = StringBuffer();
    for (final byte in output) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return buffer.toString();
  }

  /// PKCS7 填充
  Uint8List _pkcs7Pad(Uint8List input, int blockSize) {
    final padding = blockSize - (input.length % blockSize);
    return Uint8List.fromList([
      ...input,
      ...List<int>.filled(padding, padding),
    ]);
  }
}
