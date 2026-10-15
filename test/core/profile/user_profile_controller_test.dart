import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/profile/user_profile_controller.dart';

import '../../helpers/credential_store_test_ext.dart';
import '../../helpers/gated_secure_storage.dart';
import '../../helpers/test_setup.dart';

/// [UserProfileController] 的自动入学年级单测。
///
/// 覆盖：仅从已验证身份识别、升级迁移、未知学号 fail-open、登录 / 换号
/// 即时刷新、真实登出（保留已保存凭据）不残留旧年级、冷启动迟到读取不得
/// 覆盖新身份、监听挂载 / 释放幂等。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 统一认证 v2 session envelope 的持久 key（CredentialStore 私有常量，
  // 测试用字面量固定；非敏感）。
  const unifiedSessionKey = 'zjxu_ua_session_v2';

  setUp(() async {
    await resetTestEnvironment();
  });

  /// 真实登录 / 换号 / 登出路径会在身份变化后发出变更通知；debugSetSession
  /// 只改内存身份（与 `changxing_jiada_token_binding_test` 的 signIn/signOut
  /// 用法一致），这里补发同一通知。
  void notifyUnified() {
    // ignore: invalid_use_of_protected_member
    UnifiedAuthService.instance.notifyListeners();
  }

  void notifyZhengfang() {
    // ignore: invalid_use_of_protected_member
    ZhengfangAuth.instance.notifyListeners();
  }

  test(
    'legacy manual enrollment pref is ignored and cleared on init',
    () async {
      SharedPreferences.setMockInitialValues({
        UserProfileController.legacyManualEnrollmentYearKey: 2020,
      });

      await UserProfileController.instance.init();

      // 迁移只清理遗留 key，不动其他偏好。
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(UserProfileController.legacyManualEnrollmentYearKey),
        isNull,
      );

      // 生效年级来自身份自动识别，历史手动值不再覆盖；此时内存无身份，
      // 走冷启动持久 envelope 恢复。
      await CredentialStore.instance.saveUnifiedAuthSession('20240101');
      await UserProfileController.instance.refreshAutoEnrollmentYear();
      expect(UserProfileController.instance.effectiveEnrollmentYear, 2024);
      expect(
        prefs.getInt(UserProfileController.legacyManualEnrollmentYearKey),
        isNull,
      );
    },
  );

  test(
    'login notification infers year from verified memory identity',
    () async {
      await UserProfileController.instance.init();

      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20230101',
      );
      notifyUnified();

      expect(UserProfileController.instance.effectiveEnrollmentYear, 2023);
    },
  );

  test(
    'unknown identity format stays unknown (fail-open, no guessing)',
    () async {
      await UserProfileController.instance.init();

      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '32123456',
      );
      notifyUnified();

      expect(UserProfileController.instance.effectiveEnrollmentYear, isNull);
    },
  );

  test('unified verified account takes precedence over zhengfang id', () async {
    await UserProfileController.instance.init();

    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20230101');
    notifyZhengfang();
    expect(UserProfileController.instance.effectiveEnrollmentYear, 2023);

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20240101',
    );
    notifyUnified();
    expect(UserProfileController.instance.effectiveEnrollmentYear, 2024);

    // 正方换号不得越过更高优先级的统一认证身份。
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20220101');
    notifyZhengfang();
    expect(UserProfileController.instance.effectiveEnrollmentYear, 2024);
  });

  test(
    'real logout clears year immediately and after revoke, keeps credentials',
    () async {
      await UserProfileController.instance.init();
      // 合成的「记住的凭据」+ 激活会话：登出按设计只撤销会话，不删凭据。
      await CredentialStore.instance.saveCredentials(
        '20240101',
        'synthetic-secret',
      );
      await CredentialStore.instance.saveUnifiedAuthSession('20240101');

      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20240101',
      );
      notifyUnified();
      expect(UserProfileController.instance.effectiveEnrollmentYear, 2024);

      // 真实登出：内存先清并通知，持久撤销随后 await 完成。
      await UnifiedAuthService.instance.markLoggedOut();
      expect(
        UserProfileController.instance.effectiveEnrollmentYear,
        isNull,
        reason: '登出通知后年级应立即变为 unknown',
      );

      // 持久撤销完成后依旧 unknown；保存的凭据仍在（profile 不清凭据）。
      expect(UserProfileController.instance.effectiveEnrollmentYear, isNull);
      expect(await CredentialStore.instance.loadCredentials(), isNotNull);
    },
  );

  test('late cold-start read cannot overwrite a newer logout', () async {
    final storage = GatedSecureStoragePlatform()..install();
    await UserProfileController.instance.init();
    // 冷启动：盘上有激活的统一认证会话，内存尚无身份。
    await CredentialStore.instance.saveUnifiedAuthSession('20240101');

    // 挂起冷启动读取，模拟慢读。
    final heldRead = storage.holdNext(
      SecureStorageOperation.read,
      unifiedSessionKey,
    );
    final refresh = UserProfileController.instance.refreshAutoEnrollmentYear();
    await heldRead.started.future;

    // 读取未返回期间发生真实登出（内存先清、通知先发、持久撤销随后）。
    await UnifiedAuthService.instance.markLoggedOut();
    expect(UserProfileController.instance.effectiveEnrollmentYear, isNull);

    // 释放迟到的冷启动读取：旧持久身份不得复活年级。
    heldRead.release();
    await refresh;
    expect(
      UserProfileController.instance.effectiveEnrollmentYear,
      isNull,
      reason: '迟到的冷启动读取不得覆盖更新的登出状态',
    );
  });

  test(
    'repeated init is idempotent and debugReset detaches listeners',
    () async {
      await UserProfileController.instance.init();
      await UserProfileController.instance.init();
      await UserProfileController.instance.init();

      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20240101',
      );
      notifyUnified();
      expect(UserProfileController.instance.effectiveEnrollmentYear, 2024);

      UserProfileController.instance.debugReset();
      expect(UserProfileController.instance.effectiveEnrollmentYear, isNull);

      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20220101',
      );
      notifyUnified();
      expect(
        UserProfileController.instance.effectiveEnrollmentYear,
        isNull,
        reason: 'debugReset 后不再响应认证通知',
      );
    },
  );
}
