import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_preferences_controller.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:jxu_campus_hub/core/push/push_service.dart';
import 'package:jxu_campus_hub/core/shortcut/app_shortcut_service.dart';
import 'package:jxu_campus_hub/core/update/update_checker.dart';
import 'package:jxu_campus_hub/core/update/update_service.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/service_hub/service_hub_usage_store.dart';

Future<void> resetTestEnvironment() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: '嘉兴大学-智能中台',
    packageName: 'test.package',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: 'test',
  );

  GlassStyleController.instance.debugReset();
  AppPreferencesController.instance.debugReset();
  UnifiedAuthService.instance.debugReset();
  ZhengfangAuth.instance.debugReset();
  ConnectModeResolver.instance.debugReset();
  NetworkSettings.instance.debugReset();
  DioClient.instance.debugReset();
  AppLogger.instance.debugReset();
  AppShortcutService.instance.debugReset();
  UpdateService.instance.debugReset();
  UpdateChecker.instance.debugReset();
  CampusCardService.instance.debugSetCachedBalance(null);
  ChangxingJiadaService.instance.debugReset();
  DormElectricityService.instance.debugReset();
  await ScheduleService.instance.debugClearCache();
  PushService.instance.debugReset();
  ExamService.instance.debugReset();
  GradesService.instance.debugReset();
  ServiceHubUsageStore.instance.debugReset();
}
