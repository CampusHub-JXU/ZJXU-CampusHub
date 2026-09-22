import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 私有缓存的单条原子 envelope。
///
/// 一条记录 = 一个 storage key 的**单次** `setString` / `write`，因此
/// owner / updatedAt / epoch / payload 不会出现「写了 data 却没写 owner」的
/// 中间态，并发写入者只会读到其中一条完整记录，而不是两次写入的混合。
///
/// [owner] 是明确的账号标识（教务学号 / CAS 账号）；[epoch] 是 auth 层的
/// **持久身份纪元**（`AuthSessionPersistence` envelope 的 `epoch`），跨
/// isolate / 跨重启稳定，用于拒绝旧身份写入与旧记录读取。进程内
/// `sessionRevision` 不落盘。
class PrivateCacheEnvelope {
  const PrivateCacheEnvelope({
    required this.owner,
    required this.updatedAt,
    required this.epoch,
    required this.payload,
  });

  /// 载荷结构版本。v1（无 epoch）无法证明属于哪个身份纪元，整条作废。
  static const int schemaVersion = 2;

  final String owner;
  final DateTime updatedAt;
  final int epoch;
  final Object? payload;

  bool belongsTo(String account, int durableEpoch) =>
      owner == account && epoch == durableEpoch;

  String encode() => jsonEncode(<String, dynamic>{
    'v': schemaVersion,
    'owner': owner,
    'updatedAt': updatedAt.toIso8601String(),
    'epoch': epoch,
    'payload': payload,
  });

  /// 解析失败 / 版本不符 / owner 为空 / 时间戳缺失 / epoch 缺失一律无效
  /// （null），调用方按「无有效记录」处理并下次刷新。
  static PrivateCacheEnvelope? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != schemaVersion) return null;
      final owner = decoded['owner']?.toString().trim() ?? '';
      if (owner.isEmpty) return null;
      final updatedAt = DateTime.tryParse(
        decoded['updatedAt']?.toString() ?? '',
      );
      if (updatedAt == null) return null;
      final epoch = decoded['epoch'];
      if (epoch is! int) return null;
      return PrivateCacheEnvelope(
        owner: owner,
        updatedAt: updatedAt,
        epoch: epoch,
        payload: decoded['payload'],
      );
    } catch (_) {
      return null;
    }
  }
}

/// 单 key 原子读写；owner / epoch 归属与 TTL 校验由调用方负责。
abstract class PrivateCacheStore {
  Future<PrivateCacheEnvelope?> read();

  Future<void> write(PrivateCacheEnvelope envelope);

  Future<void> clear();
}

/// SharedPreferences 后端。读取前 `reload()`，避免命中其他 isolate 写盘前
/// 的内存镜像。
class SharedPreferencesPrivateCacheStore implements PrivateCacheStore {
  SharedPreferencesPrivateCacheStore(this.key);

  final String key;

  @override
  Future<PrivateCacheEnvelope?> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return PrivateCacheEnvelope.tryDecode(prefs.getString(key));
  }

  @override
  Future<void> write(PrivateCacheEnvelope envelope) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, envelope.encode());
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// FlutterSecureStorage 后端（校园卡余额等敏感值）。
class SecureStoragePrivateCacheStore implements PrivateCacheStore {
  SecureStoragePrivateCacheStore(this.key, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final String key;
  final FlutterSecureStorage _storage;

  @override
  Future<PrivateCacheEnvelope?> read() async =>
      PrivateCacheEnvelope.tryDecode(await _storage.read(key: key));

  @override
  Future<void> write(PrivateCacheEnvelope envelope) =>
      _storage.write(key: key, value: envelope.encode());

  @override
  Future<void> clear() => _storage.delete(key: key);
}
