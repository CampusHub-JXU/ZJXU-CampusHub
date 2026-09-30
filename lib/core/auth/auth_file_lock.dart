import 'dart:io';
import 'dart:math';

/// 获取文件锁超时（有限等待），避免调用方无限阻塞。
class AuthLockTimeoutException implements Exception {
  const AuthLockTimeoutException([this.message = '获取认证文件锁超时']);

  final String message;

  @override
  String toString() => message;
}

/// 跨 isolate / 跨进程的排他文件锁（O_EXCL 创建 + 持有者 token）。
///
/// 与 `NoticeSyncStore` 的锁实现同源：`create(exclusive: true)` 按 inode
/// 原子判冲突，同进程多 isolate 与跨进程都正确串行化；fcntl 句柄锁在
/// Linux 按 process 判冲突，同进程第二个加锁方不被阻塞，故不采用。
///
/// 锁挂在独立文件而非被 rename 替换的状态文件上；残留锁（持有者崩溃、
/// 旧版本遗留空锁）靠超龄回收兜底。
///
/// **适用范围**：只用于**短时**状态读改写（毫秒级本地 IO）。**禁止**用它
/// 围住网络请求、OCR 或等待用户输入——那会让超龄回收误判“活跃锁”并把
/// 正在网络中的持锁者踢出临界区。长时间操作不得持锁：自动登录交换本身
/// **不持有任何文件锁**，只在锁内做状态读改写，网络/OCR 在锁外进行。
///
/// 跨 isolate 的登录互斥由「自动登录以前台为主、后台仅经 BackgroundSessionGate 申领的有限例外」
/// 规避（见 `AuthOperationCoordinator`），本锁只负责状态读改写的原子性。
///
/// **调用约束**：锁内只做内存与本地文件操作；不得反向再取外层锁——固定
/// 加锁顺序见 `AuthOperationCoordinator`。
class AuthFileLock {
  AuthFileLock({
    required this.lockFile,
    this.staleLockAge = const Duration(seconds: 60),
    this.emptyLockGraceAge = const Duration(milliseconds: 250),
    this.maxPollDelay = const Duration(milliseconds: 50),
    this.acquireTimeout,
  });

  final File lockFile;

  /// 有 token 的锁超过该时长视为持有者已死，可回收。仅当锁只被短时持有
  /// 时该启发式才安全；长任务请改用 lease。
  final Duration staleLockAge;

  /// 空锁文件宽限期：create 与 token 写入之间的合法空窗，视作活跃取锁中态。
  final Duration emptyLockGraceAge;

  final Duration maxPollDelay;

  /// 有限等待上限；到点抛 [AuthLockTimeoutException]。null 表示不设上限
  /// （仅限短时锁，仍建议设置）。
  final Duration? acquireTimeout;

  final Random _random = Random();

  Future<T> withLock<T>(Future<T> Function() action) async {
    final token = await acquire();
    try {
      return await action();
    } finally {
      await release(token);
    }
  }

  Future<String> acquire() async {
    final token =
        'pid-$pid-${DateTime.now().microsecondsSinceEpoch}-'
        '${identityHashCode(this)}-${_random.nextInt(0x7fffffff)}';
    final timeout = acquireTimeout;
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    var delay = const Duration(milliseconds: 1);
    while (true) {
      if (deadline != null && !DateTime.now().isBefore(deadline)) {
        throw const AuthLockTimeoutException();
      }
      try {
        await lockFile.create(exclusive: true);
        final raf = await lockFile.open(mode: FileMode.append);
        try {
          await raf.writeString(token);
          await raf.flush();
        } finally {
          await raf.close();
        }
        // 校验锁内容仍是自己的 token：写入期间锁可能被回收重取。
        if (await _readTokenSafe() == token) return token;
      } on FileSystemException catch (error) {
        if (!_isPathExistsError(error)) rethrow;
        if (await _tryRecoverStaleLock()) continue;
      }
      await Future<void>.delayed(delay);
      if (delay < maxPollDelay) delay *= 2;
    }
  }

  Future<void> release(String token) async {
    try {
      final content = await _readTokenSafe();
      if (content != null && content.startsWith(token)) {
        await lockFile.delete();
      }
    } on FileSystemException {
      // 锁已被回收或读取失败：无需处理。
    }
  }

  Future<String?> _readTokenSafe() async {
    try {
      return await lockFile.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  bool _isPathExistsError(FileSystemException error) {
    if (error is PathExistsException) return true;
    final code = error.osError?.errorCode;
    // EEXIST (POSIX) / ERROR_ALREADY_EXISTS (Windows)。
    return code == 17 || code == 183;
  }

  Future<bool> _tryRecoverStaleLock() async {
    try {
      final stat = await lockFile.stat();
      final age = DateTime.now().difference(stat.modified);
      final isAged = age >= staleLockAge;
      final isEmptyAged = stat.size == 0 && age >= emptyLockGraceAge;
      if (!isAged && !isEmptyAged) return false;
      await lockFile.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
