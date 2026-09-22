import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/features/schedule/controllers/schedule_page_controller.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_term_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final today = DateTime.now();
    SemesterCalendar.instance.semesterStartDate.value = DateTime(
      today.year,
      today.month,
      today.day,
    );
    await ScheduleService.instance.restoreCache();
    await ScheduleService.instance.debugClearCache();
  });

  SchedulePageController controllerWith(
    Future<ScheduleLoadResult> Function({
      ScheduleTermContext? termContext,
      String? studentId,
      bool forceRefresh,
    })
    loader,
  ) {
    final controller = SchedulePageController(loggedIn: true, loader: loader);
    addTearDown(controller.dispose);
    return controller;
  }

  test('propagates automaticLoginPaused from the load result', () async {
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async => const ScheduleLoadResult(
        requiresLogin: true,
        automaticLoginPaused: true,
      ),
    );

    expect(controller.automaticLoginPaused, isFalse);
    await controller.fetchSchedule();
    expect(controller.automaticLoginPaused, isTrue);
  });

  test('ordinary load result keeps the pause flag false', () async {
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async => const ScheduleLoadResult(message: 'ok'),
    );

    await controller.fetchSchedule();
    expect(controller.automaticLoginPaused, isFalse);
  });

  test('manual login success clears the pause flag', () async {
    final controller = controllerWith(
      ({
        ScheduleTermContext? termContext,
        String? studentId,
        bool forceRefresh = false,
      }) async => const ScheduleLoadResult(
        requiresLogin: true,
        automaticLoginPaused: true,
      ),
    );

    await controller.fetchSchedule();
    expect(controller.automaticLoginPaused, isTrue);

    controller.onLoginSuccess();
    expect(controller.automaticLoginPaused, isFalse);
  });
}
