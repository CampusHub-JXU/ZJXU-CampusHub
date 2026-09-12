import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/library/library_session.dart';

import '../../helpers/test_setup.dart';

const _accountA = 'TEST_LIB_ACCOUNT_A';
const _accountB = 'TEST_LIB_ACCOUNT_B';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    LibrarySession.instance.debugReset();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: _accountA,
    );
  });

  tearDown(() {
    LibrarySession.instance.debugReset();
  });

  test('bindToken 绑定当前账号，登出后缓存立即失效', () async {
    expect(LibrarySession.instance.bindToken('token-a'), isTrue);
    expect(LibrarySession.instance.accessToken, 'token-a');

    await UnifiedAuthService.instance.markLoggedOut();

    expect(LibrarySession.instance.accessToken, isNull);
  });

  test('未登录 / 空令牌拒绝绑定，不缓存身份未知的令牌', () {
    UnifiedAuthService.instance.debugSetSession(active: false);
    expect(LibrarySession.instance.bindToken('token-a'), isFalse);
    expect(LibrarySession.instance.accessToken, isNull);

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: _accountA,
    );
    expect(LibrarySession.instance.bindToken('  '), isFalse);
    expect(LibrarySession.instance.accessToken, isNull);
  });

  test('账号切换后旧账号缓存令牌不可见', () {
    expect(LibrarySession.instance.bindToken('token-a'), isTrue);

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: _accountB,
    );

    expect(LibrarySession.instance.accessToken, isNull);
  });

  test('同账号重登（epoch 变化）后旧令牌作废', () {
    expect(LibrarySession.instance.bindToken('token-a'), isTrue);

    // 登录成功即使账号不变也会 notifyListeners：图书馆 localStorage 可能仍是
    // 旧身份写的，必须重新读取。
    LibrarySession.instance.debugHandleAuthChanged();

    expect(LibrarySession.instance.accessToken, isNull);
  });

  test('clearToken 清空令牌与绑定', () {
    expect(LibrarySession.instance.bindToken('token-a'), isTrue);

    LibrarySession.instance.clearToken();

    expect(LibrarySession.instance.accessToken, isNull);
  });

  test('捕获成功时绑定当前账号，可被借阅页消费', () async {
    LibrarySession.instance.debugMaxAttempts = 1;
    LibrarySession.instance.debugTokenReadOverride = () async => '"token-a"';

    await LibrarySession.instance.debugCapture();

    expect(LibrarySession.instance.accessToken, 'token-a');
  });

  test('捕获轮询期间切号：迟到的旧账号令牌被丢弃', () async {
    var reads = 0;
    LibrarySession.instance.debugMaxAttempts = 3;
    LibrarySession.instance.debugRetryInterval = Duration.zero;
    LibrarySession.instance.debugTokenReadOverride = () async {
      reads++;
      if (reads == 1) return '';
      // 第一次读空后账号被切换，第二次才读到旧 WebView 的令牌。
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: _accountB,
      );
      return '"late-token-a"';
    };

    await LibrarySession.instance.debugCapture();

    expect(reads, greaterThanOrEqualTo(2));
    expect(LibrarySession.instance.accessToken, isNull);
  });

  test('捕获轮询期间同账号重登（epoch 变化）：迟到的令牌被丢弃', () async {
    var reads = 0;
    LibrarySession.instance.debugMaxAttempts = 2;
    LibrarySession.instance.debugRetryInterval = Duration.zero;
    LibrarySession.instance.debugTokenReadOverride = () async {
      reads++;
      if (reads == 1) return '';
      LibrarySession.instance.debugHandleAuthChanged();
      return 'late-token-a';
    };

    await LibrarySession.instance.debugCapture();

    expect(LibrarySession.instance.accessToken, isNull);
  });

  test('ensureGuard 在账号或纪元变化时拒绝旧操作', () {
    final guard = LibrarySession.instance.captureGuard();
    LibrarySession.instance.ensureGuard(guard);

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: _accountB,
    );
    expect(
      () => LibrarySession.instance.ensureGuard(guard),
      throwsA(isA<LibrarySessionChangedException>()),
    );

    final epochGuard = LibrarySession.instance.captureGuard();
    LibrarySession.instance.debugHandleAuthChanged();
    expect(
      () => LibrarySession.instance.ensureGuard(epochGuard),
      throwsA(isA<LibrarySessionChangedException>()),
    );
  });
}
