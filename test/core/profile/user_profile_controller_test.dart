import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/profile/user_profile_controller.dart';

import '../../helpers/credential_store_test_ext.dart';
import '../../helpers/test_setup.dart';

/// [UserProfileController] 的自动入学年级单测：仅从已登录学号识别，
/// 不再有任何可在 UI 编辑的持久手动覆盖。覆盖升级迁移、识别、
/// 未知学号 fail-open、登录 / 换号 / 登出刷新四条路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

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

      // 生效年级来自学号自动识别，历史手动值不再覆盖。
      await CredentialStore.instance.saveUnifiedAuthSession('20240101');
      await UserProfileController.instance.refreshAutoEnrollmentYear();
      expect(UserProfileController.instance.effectiveEnrollmentYear, 2024);
      expect(
        prefs.getInt(UserProfileController.legacyManualEnrollmentYearKey),
        isNull,
      );
    },
  );

  test('known valid student id infers enrollment year', () async {
    await CredentialStore.instance.saveUnifiedAuthSession('20230101');

    await UserProfileController.instance.refreshAutoEnrollmentYear();

    expect(UserProfileController.instance.effectiveEnrollmentYear, 2023);
  });

  test('unknown student id yields unknown (fail-open, no guessing)', () async {
    await CredentialStore.instance.saveUnifiedAuthSession('32123456');

    await UserProfileController.instance.refreshAutoEnrollmentYear();

    expect(UserProfileController.instance.effectiveEnrollmentYear, isNull);
  });

  test('auth notification refreshes on account switch and logout', () async {
    await UserProfileController.instance.init();

    await CredentialStore.instance.saveUnifiedAuthSession('20240101');
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20240101',
    );
    // 真实登录 / 换号路径会发出变更通知；debugSetSession 只改内存身份。
    // ignore: invalid_use_of_protected_member
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();
    expect(UserProfileController.instance.effectiveEnrollmentYear, 2024);

    await CredentialStore.instance.saveUnifiedAuthSession('20220101');
    // ignore: invalid_use_of_protected_member
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();
    expect(UserProfileController.instance.effectiveEnrollmentYear, 2022);

    await CredentialStore.instance.clearUnifiedAuthSession();
    // ignore: invalid_use_of_protected_member
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();
    expect(UserProfileController.instance.effectiveEnrollmentYear, isNull);
  });
}
