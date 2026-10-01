import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// 应用支持目录下单个 JSON 状态文件的共享 IO：目录解析、
/// 临时文件 + rename 原子写、带「损坏回调」的读取。
///
/// 只负责 IO。损坏读取的**策略**（删除重建 / fail closed / 注入无效标记）
/// 由各调用方通过 [read] 的 `onCorrupt` 自己决定；锁（[AuthFileLock]）也由
/// 调用方持有——本类不做任何并发串行化。
class AtomicJsonFile {
  AtomicJsonFile(this.fileName, {this.directory});

  final String fileName;

  /// 返回 null（或本身为 null）表示使用应用支持目录；用于惰性读取调用方
  /// 随时可变的测试替身（`debugDirectoryProvider`）。
  final Future<Directory>? Function()? directory;

  static final Random _random = Random();

  /// 目录：优先用注入的 provider（测试替身），否则应用支持目录。
  Future<Directory> resolveDirectory() async {
    final override = directory?.call();
    if (override != null) return override;
    return getApplicationSupportDirectory();
  }

  Future<File> file() => siblingFile(fileName);

  /// 同目录下的另一个文件（如独立 `.lock` 文件）。不预创建。
  Future<File> siblingFile(String name) async {
    final dir = await resolveDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// 读取并解码。文件不存在返回 [absent]；读取 / JSON 解析 / [decode] 抛错
  /// 一律交给 [onCorrupt]（可在其中删除文件、记日志、返回 fail-closed 值）。
  Future<T> read<T>(
    File target, {
    required T absent,
    required T Function(Object? json) decode,
    required FutureOr<T> Function(Object error, StackTrace stackTrace)
    onCorrupt,
  }) async {
    if (!await target.exists()) return absent;
    try {
      return decode(jsonDecode(await target.readAsString()));
    } catch (error, stackTrace) {
      return onCorrupt(error, stackTrace);
    }
  }

  /// 临时文件 + rename 原子替换。每次写入用独立临时名：POSIX rename 语义
  /// 下共享临时名会让并发写者互相搬走对方的文件（ENOENT）。
  static Future<void> write(File target, Object? json) async {
    final tmp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}'
      '-${_random.nextInt(0x7fffffff)}.tmp',
    );
    await tmp.writeAsString(jsonEncode(json), flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 尽力删除（忽略一切错误）。
  static Future<void> safeDelete(File target) async {
    try {
      if (await target.exists()) await target.delete();
    } catch (_) {}
  }
}
