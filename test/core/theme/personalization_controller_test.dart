import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';

void main() {
  final controller = PersonalizationController.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller.debugReset();
  });

  test('home defaults enable watermark and courses but hide notices', () async {
    await controller.init();

    expect(controller.emblemWatermarkEnabled.value, isTrue);
    expect(controller.fullDayCoursesEnabled.value, isTrue);
    expect(controller.homeCampusNoticeEnabled.value, isFalse);
  });

  test('init restores disabled home presentation preferences', () async {
    SharedPreferences.setMockInitialValues({
      'home_emblem_watermark_enabled': false,
      'home_full_day_courses_enabled': false,
      'home_campus_notice_enabled': false,
    });

    await controller.init();

    expect(controller.emblemWatermarkEnabled.value, isFalse);
    expect(controller.fullDayCoursesEnabled.value, isFalse);
    expect(controller.homeCampusNoticeEnabled.value, isFalse);
  });

  test('home presentation preference setters persist values', () async {
    await controller.setEmblemWatermarkEnabled(false);
    await controller.setFullDayCoursesEnabled(false);
    await controller.setHomeCampusNoticeEnabled(false);

    controller.debugReset();
    await controller.init();

    expect(controller.emblemWatermarkEnabled.value, isFalse);
    expect(controller.fullDayCoursesEnabled.value, isFalse);
    expect(controller.homeCampusNoticeEnabled.value, isFalse);
  });
}
