import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/network/network_settings.dart';
import 'core/semester/semester_calendar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SemesterCalendar.instance.init();
  await NetworkSettings.instance.init();
  runApp(const JiaxingUniversityApp());
}
