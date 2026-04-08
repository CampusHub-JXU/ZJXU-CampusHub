import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/theme_mode_controller.dart';
import 'core/auth/unified_auth.dart';
import 'core/auth/zhengfang_auth.dart';
import 'core/logging/app_logger.dart';
import 'core/network/dio_client.dart';
import 'core/network/network_settings.dart';
import 'core/semester/semester_calendar.dart';
import 'features/campus_card/campus_card_service.dart';
import 'features/changxing_jiada/changxing_jiada_service.dart';
import 'features/dorm_electricity/dorm_electricity_service.dart';
import 'features/schedule/schedule_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.instance.init();
  await DioClient.instance.init();
  await Future.wait([
    SemesterCalendar.instance.init(),
    NetworkSettings.instance.init(),
    ThemeModeController.instance.init(),
    ZhengfangAuth.instance.restoreSession(),
    UnifiedAuthService.instance.restoreSession(syncWebViewCookies: false),
    CampusCardService.instance.restoreBalance(),
    ChangxingJiadaService.instance.restoreSession(),
    DormElectricityService.instance.restoreCache(),
    ScheduleService.instance.restoreCache(),
  ]);
  runApp(const JiaxingUniversityApp());
}
