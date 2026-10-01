import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 统一认证密码加密工具
///
/// 使用 AES-128-CBC 模式加密密码，PKCS7 填充。
/// 与前端 JavaScript main.js 中的加密逻辑保持一致。
class AuthCrypto {
  AuthCrypto._();
  static final AuthCrypto instance = AuthCrypto._();

  /// AES-128 密钥 (16 字符)，来自前端 main.js 的 aes1 变量。
  ///
  /// 这是前端公开的固定约定值（攻击者可从公开前端代码获取），
  /// 放进 secure storage 并不能提高安全性。
  static const String _aesKey = 'key_value_123456';

  /// AES IV (16 字符)，来自前端 main.js 的 akey 变量。
  static const String _aesIv = '0987654321123456';

  /// AES-128 块大小 (16 字节)。
  static const int _blockSize = 16;

  /// AES-128-CBC 加密密码
  ///
  /// 使用与前端约定的固定密钥和 IV，返回十六进制字符串 (大写)。
  String encryptPassword(String password) {
    final keyBytes = Uint8List.fromList(utf8.encode(_aesKey));
    final ivBytes = Uint8List.fromList(utf8.encode(_aesIv));
    final input = Uint8List.fromList(utf8.encode(password));

    final paddedInput = _pkcs7Pad(input, _blockSize);

    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(keyBytes), ivBytes));

    final output = Uint8List(paddedInput.length);
    for (var offset = 0; offset < paddedInput.length; offset += _blockSize) {
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
