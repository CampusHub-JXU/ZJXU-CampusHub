import 'schedule_constants.dart';

class ScheduleSlotTimes {
  ScheduleSlotTimes._();

  static const slotTimes = scheduleSlotTimes;

  static String startTime(int lesson) =>
      (lesson >= 1 && lesson <= scheduleSlotCount)
      ? scheduleSlotTimes[lesson - 1][0]
      : scheduleUnknownTimeText;

  static String endTime(int lesson) =>
      (lesson >= 1 && lesson <= scheduleSlotCount)
      ? scheduleSlotTimes[lesson - 1][1]
      : scheduleUnknownTimeText;

  static String timeRange(int start, int end) =>
      '${startTime(start)}-${endTime(end)}';
}
