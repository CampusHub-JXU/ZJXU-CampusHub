import 'dart:async';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// flutter_secure_storage_platform_interface 是 flutter_secure_storage 的传递
// 依赖；安装可控替身必须引用平台接口类型本身（不为此新增 pubspec 依赖）。
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// secure storage 操作类型。
enum SecureStorageOperation { read, write, delete }

/// 一次被测试挂起的 secure storage 调用。
class HeldSecureStorageCall {
  HeldSecureStorageCall(this.operation, this.key);

  final SecureStorageOperation operation;
  final String key;

  /// 调用已进入平台层（挂起前）。
  final Completer<void> started = Completer<void>();

  /// 测试释放后调用才会真正读写底层 map。
  final Completer<void> released = Completer<void>();

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

/// 可控的 secure storage 平台替身：正常行为与
/// [TestFlutterSecureStoragePlatform] 一致（内存 map + `data`），但可通过
/// [holdNext] 让下一次匹配的调用在进入平台层后挂起，直到测试显式
/// [HeldSecureStorageCall.release]。用于确定性地复现「旧会话的写入 / 删除
/// 晚到」这类竞态，而不依赖真实时序。
class GatedSecureStoragePlatform extends TestFlutterSecureStoragePlatform {
  GatedSecureStoragePlatform() : super(<String, String>{});

  /// 每次进入平台层的调用顺序（`read:key` / `write:key` / `delete:key`）。
  final List<String> operationLog = <String>[];

  /// 已被挂起过的调用（按进入顺序）。
  final List<HeldSecureStorageCall> heldCalls = <HeldSecureStorageCall>[];

  final List<HeldSecureStorageCall> _pendingHolds = <HeldSecureStorageCall>[];

  /// 把本替身安装为全局 secure storage 平台。
  void install() => FlutterSecureStoragePlatform.instance = this;

  /// 拦截**下一次**匹配 [operation] + [key] 的调用。
  HeldSecureStorageCall holdNext(SecureStorageOperation operation, String key) {
    final call = HeldSecureStorageCall(operation, key);
    _pendingHolds.add(call);
    return call;
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    operationLog.add('write:$key');
    await _holdIfMatched(SecureStorageOperation.write, key);
    data[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    operationLog.add('delete:$key');
    await _holdIfMatched(SecureStorageOperation.delete, key);
    data.remove(key);
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    operationLog.add('read:$key');
    // 读取值在调用进入时快照：挂起的读必须返回「发起时」的值，
    // 否则并发写入会改变读结果，无法复现真实竞态。
    final snapshot = data[key];
    await _holdIfMatched(SecureStorageOperation.read, key);
    return snapshot;
  }

  Future<void> _holdIfMatched(
    SecureStorageOperation operation,
    String key,
  ) async {
    final index = _pendingHolds.indexWhere(
      (call) => call.operation == operation && call.key == key,
    );
    if (index < 0) return;
    final call = _pendingHolds.removeAt(index);
    heldCalls.add(call);
    if (!call.started.isCompleted) call.started.complete();
    await call.released.future;
  }
}
