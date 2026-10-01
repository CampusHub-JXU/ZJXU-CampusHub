import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_file_lock.dart';

void main() {
  late Directory dir;
  late File lockFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auth_file_lock_test_');
    lockFile = File('${dir.path}${Platform.pathSeparator}x.lock');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('acquire 创建锁文件，release 删除', () async {
    final lock = AuthFileLock(lockFile: lockFile);
    final token = await lock.acquire();
    expect(await lockFile.exists(), isTrue);
    expect(await lockFile.readAsString(), token);
    await lock.release(token);
    expect(await lockFile.exists(), isFalse);
  });

  test('withLock 在异常时也释放锁', () async {
    final lock = AuthFileLock(lockFile: lockFile);
    await expectLater(
      lock.withLock<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(await lockFile.exists(), isFalse);
  });

  test('release 不会删除他人持有的锁', () async {
    final lock = AuthFileLock(lockFile: lockFile);
    final token = await lock.acquire();
    await lockFile.writeAsString('someone-else');
    await lock.release(token);
    expect(await lockFile.exists(), isTrue);
  });

  test('超龄锁被回收', () async {
    await lockFile.writeAsString('dead-holder');
    final lock = AuthFileLock(
      lockFile: lockFile,
      staleLockAge: const Duration(milliseconds: 1),
      acquireTimeout: const Duration(seconds: 5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final token = await lock.acquire();
    expect(await lockFile.readAsString(), token);
    await lock.release(token);
  });

  test('空锁文件超过宽限期被回收', () async {
    await lockFile.writeAsString('');
    final lock = AuthFileLock(
      lockFile: lockFile,
      emptyLockGraceAge: const Duration(milliseconds: 10),
      acquireTimeout: const Duration(seconds: 5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final token = await lock.acquire();
    await lock.release(token);
  });

  test('活跃锁不被回收，acquireTimeout 到点抛 AuthLockTimeoutException', () async {
    final holder = AuthFileLock(lockFile: lockFile);
    final token = await holder.acquire();
    final waiter = AuthFileLock(
      lockFile: lockFile,
      acquireTimeout: const Duration(milliseconds: 150),
    );
    await expectLater(
      waiter.acquire(),
      throwsA(isA<AuthLockTimeoutException>()),
    );
    await holder.release(token);
  });

  test('并发 withLock 互斥串行', () async {
    final a = AuthFileLock(lockFile: lockFile);
    final b = AuthFileLock(lockFile: lockFile);
    var inside = 0;
    var maxInside = 0;
    var completed = 0;
    Future<void> run(AuthFileLock lock) => lock.withLock(() async {
      inside++;
      if (inside > maxInside) maxInside = inside;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      inside--;
      completed++;
    });
    await Future.wait([for (var i = 0; i < 10; i++) run(i.isEven ? a : b)]);
    expect(maxInside, 1);
    expect(completed, 10);
    expect(await lockFile.exists(), isFalse);
  });
}
