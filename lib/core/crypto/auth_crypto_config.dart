import 'package:flutter/foundation.dart';

/// 统一认证与 WebVPN CAS 登录的密码加密配置
///
/// AES 密钥来自前端 main.js 中的公开约定值:
/// - aes1 = 'key_value_123456' (密钥)
/// - akey = '0987654321123456' (IV)
///
/// 注意: 这些密钥是前端公开的固定值，与服务器约定，
/// 存储在 secure storage 中并不能提高安全性（因为攻击者可从公开前端代码获取）。
/// 集中管理的目的在于:
/// 1. 避免在多个文件中重复硬编码
/// 2. 便于未来协议更新时统一修改
/// 3. 提供类型安全的访问接口
class AuthCryptoConfig {
  AuthCryptoConfig._();
  static final AuthCryptoConfig instance = AuthCryptoConfig._();

  /// AES-128 密钥 (16 字符)
  /// 来源: 前端 main.js 中 aes1 变量
  static const String _defaultAesKey = 'key_value_123456';

  /// AES IV (16 字符)
  /// 来源: 前端 main.js 中 akey 变量
  static const String _defaultAesIv = '0987654321123456';

  /// 密钥长度必须为 16 字节 (AES-128)
  static const int aesBlockSize = 16;

  String? _overrideAesKey;
  String? _overrideAesIv;

  /// 获取当前 AES 密钥
  ///
  /// 如果设置了覆盖值则使用覆盖值，否则使用默认约定值。
  /// 自动截断到 16 字符以符合 AES-128 要求。
  String get aesKey {
    final raw = _overrideAesKey ?? _defaultAesKey;
    return _truncateToBlockSize(raw);
  }

  /// 获取当前 AES IV
  ///
  /// 如果设置了覆盖值则使用覆盖值，否则使用默认约定值。
  /// 自动截断到 16 字符以符合 AES-128 要求。
  String get aesIv {
    final raw = _overrideAesIv ?? _defaultAesIv;
    return _truncateToBlockSize(raw);
  }

  /// 设置自定义 AES 密钥 (用于测试或协议变更)
  @visibleForTesting
  void setAesKey(String key) {
    _overrideAesKey = key;
  }

  /// 设置自定义 AES IV (用于测试或协议变更)
  @visibleForTesting
  void setAesIv(String iv) {
    _overrideAesIv = iv;
  }

  /// 重置为默认值
  @visibleForTesting
  void reset() {
    _overrideAesKey = null;
    _overrideAesIv = null;
  }

  /// 截断到 16 字符 (AES-128 块大小)
  String _truncateToBlockSize(String value) {
    if (value.length > aesBlockSize) {
      return value.substring(0, aesBlockSize);
    }
    return value;
  }

  /// 检查密钥配置是否有效
  bool isValid() {
    final key = aesKey;
    final iv = aesIv;
    return key.length == aesBlockSize && iv.length == aesBlockSize;
  }
}