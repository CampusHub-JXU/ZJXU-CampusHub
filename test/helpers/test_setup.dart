import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/theme/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_event_ledger_store.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_reminder_settings.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_control.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/profile/user_profile_controller.dart';
import 'package:jxu_campus_hub/core/theme/glass_refraction.dart';
import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:jxu_campus_hub/core/shortcut/app_shortcut_service.dart';
import 'package:jxu_campus_hub/core/update/update_checker.dart';
import 'package:jxu_campus_hub/core/update/update_service.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/features/grades/progress/academic_progress_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/core/config/service_hub_usage_store.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_sync.dart';

Future<void> resetTestEnvironment() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: '嘉兴大学',
    packageName: 'test.package',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: 'test',
  );

  GlassStyleController.instance.debugReset();
  LiquidGlass.debugReset();
  PersonalizationController.instance.debugReset();
  AppPreferencesController.instance.debugReset();
  UnifiedAuthService.instance.debugReset();
  ZhengfangAuth.instance.debugReset();
  AuthRecoveryStateStore.instance.debugReset();
  AuthOperationCoordinator.instance.debugReset();
  AuthSessionPersistence.instance
    ..debugReset()
    ..debugDisableFileLock = true;
  ConnectModeResolver.instance.debugReset();
  CalendarEventLedgerStore.instance.debugReset();
  CalendarSyncControl.instance.debugReset();
  CalendarReminderSettings.instance.debugReset();
  NetworkSettings.instance.debugReset();
  DioClient.instance.debugReset();
  // widget 测试跑在 fake-async 区：文件 Cookie 存储的读盘不会完成，请求会卡在
  // CookieManager 拦截器里（adapter 收不到请求 + pumpAndSettle 超时）。统一改用
  // 内存存储，避免测试依赖真实文件 I/O。
  DioClient.instance.debugUseMemoryCookieStorage = true;
  AppLogger.instance.debugReset();
  AppShortcutService.instance.debugReset();
  UpdateService.instance.debugReset();
  UpdateChecker.instance.debugReset();
  CampusCardService.instance.debugSetCachedBalance(null);
  ChangxingJiadaService.instance.debugReset();
  Epay100Gateway.instance.debugReset();
  DormElectricityService.instance.debugSetGateway(Epay100Gateway.instance);
  DormElectricityService.instance.debugReset();
  await ScheduleService.instance.debugClearCache();
  ExamService.instance.debugReset();
  GradesService.instance.debugReset();
  AcademicProgressService.instance.debugReset();
  ServiceHubUsageStore.instance.debugReset();
  UserProfileController.instance.debugReset();
  CampusWidgetSync.instance.debugReset();
  // 桌面组件同步的 debounce 会创建 App 级 Timer；测试里归零走同步路径。
  CampusWidgetSync.instance.debugSetDebounce(Duration.zero);
}
