import 'dart:async';
import 'dart:io';

/// `flutter test` 会为 `test/` 下每个测试文件自动套用本文件的 [testExecutable]。
///
/// 每个测试文件跑在独立的 flutter_tester 进程里，进程内单例互不影响；真正跨进程
/// 共享的只有文件系统：不少测试把 path_provider mock 成 `Directory.systemTemp.path`，
/// Cookie / 认证持久化 / 缓存文件会落到同一个系统临时目录，并行跑时互相覆盖。
/// 这里给每个进程换一个独立的临时根目录，让 `flutter test` 可以安全地用默认并发。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final realTemp = Directory.systemTemp;
  final isolatedTemp = realTemp.createTempSync('jxu_test_${pid}_');
  IOOverrides.global = _IsolatedTempOverrides(isolatedTemp);
  await testMain();
}

final class _IsolatedTempOverrides extends IOOverrides {
  _IsolatedTempOverrides(this._temp);

  final Directory _temp;

  @override
  Directory getSystemTempDirectory() => _temp;
}
