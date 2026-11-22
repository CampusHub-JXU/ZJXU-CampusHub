import '../../../core/academic/exam_model.dart';
import '../../second_classroom/second_classroom_model.dart';

/// 「今日」板块中的一条近期考试（未来 1..7 天，不含今日；今日考试由
/// [HomeTodayPresentation.exams] 承接）。
class HomeUpcomingExamItem {
  const HomeUpcomingExamItem({
    required this.courseName,
    required this.dateLabel,
    required this.timeRange,
    required this.locationText,
    required this.daysUntil,
  });

  final String courseName;

  /// 日期倒计时标签，如「明天」「3天后」。
  final String dateLabel;

  /// 考试时间段，如「09:00-11:00」或「时间待定」。
  final String timeRange;

  /// 校区与地点合并文案；无地点时为空串。
  final String locationText;

  /// 距离今天的天数（1..7）。
  final int daysUntil;

  /// 两天内考试视为紧急提醒。
  bool get isUrgent => daysUntil <= 2;
}

/// 「今日」板块中的一条近期二课活动（来自本地订阅或已报名缓存）。
class HomeUpcomingActivityItem {
  const HomeUpcomingActivityItem({
    required this.id,
    required this.title,
    required this.timeLabel,
    required this.locationText,
    required this.badgeLabel,
    required this.isOngoing,
  });

  final int id;
  final String title;

  /// 开始时间文案，如「进行中」「今天 14:00」「明天 19:00」「11月24日 14:00」。
  final String timeLabel;

  /// 活动地点；无地点时为空串。
  final String locationText;

  /// 来源/状态标签：「已报名」或「已订阅」。
  final String badgeLabel;

  final bool isOngoing;
}

/// 「今日」板块除课表外的聚合扩展数据（全部来自本地缓存，零网络）。
class HomeTodayAgenda {
  const HomeTodayAgenda({
    this.upcomingExams = const [],
    this.upcomingActivities = const [],
  });

  static const empty = HomeTodayAgenda();

  /// 未来 1..7 天内考试（按日期升序，最多 3 条）。
  final List<HomeUpcomingExamItem> upcomingExams;

  /// 未来 7 天内或今日进行中的已报名/已订阅二课活动（按开始时间升序，最多 3 条）。
  final List<HomeUpcomingActivityItem> upcomingActivities;

  bool get hasExtras =>
      upcomingExams.isNotEmpty || upcomingActivities.isNotEmpty;
}

/// 纯函数：从本地缓存列表派生首页「今日」板块的近期考试与二课活动。
///
/// 不读取 `DateTime.now()`，全部基于 [now] 判定，方便单元测试。
HomeTodayAgenda resolveHomeTodayAgenda({
  required DateTime now,
  required List<ExamEntry> exams,
  required List<SecondClassroomActivity> subscribedActivities,
  required List<SecondClassroomActivity> cachedActivities,
  String? excludeExamCourseName,
  int maxExams = 3,
  int maxActivities = 3,
  int windowDays = 7,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final excludedCourse = excludeExamCourseName?.trim();

  // 1. 未来 1..windowDays 天内的考试（跳过今天：今天考试已在 HomeTodaySection；
  // 跳过已在 Hero 展示的同一门考试，避免同屏重复）。
  final examCandidates = <(DateTime, HomeUpcomingExamItem)>[];
  for (final exam in exams) {
    final rawDate = exam.examDate;
    if (rawDate == null) continue;
    if (excludedCourse != null &&
        excludedCourse.isNotEmpty &&
        exam.courseName.trim() == excludedCourse) {
      continue;
    }
    final examDay = DateTime(rawDate.year, rawDate.month, rawDate.day);
    final delta = examDay.difference(today).inDays;
    if (delta < 1 || delta > windowDays) continue;

    final locationText = _joinLocation(exam.campus, exam.location);
    examCandidates.add((
      examDay,
      HomeUpcomingExamItem(
        courseName: exam.courseName,
        dateLabel: delta == 1 ? '明天' : '$delta天后',
        timeRange: exam.timeRange.isEmpty ? '时间待定' : exam.timeRange,
        locationText: locationText,
        daysUntil: delta,
      ),
    ));
  }
  examCandidates.sort((a, b) => a.$1.compareTo(b.$1));
  final upcomingExams = examCandidates
      .take(maxExams)
      .map((entry) => entry.$2)
      .toList();

  // 2. 二课活动：合并已报名（缓存桶）与已订阅（本地持久化），去重且已报名优先。
  final merged =
      <String, ({SecondClassroomActivity activity, bool registered})>{};
  for (final activity in cachedActivities) {
    if (!activity.isRegistered) continue;
    final key = _activityKey(activity);
    merged[key] = (activity: activity, registered: true);
  }
  for (final activity in subscribedActivities) {
    final key = _activityKey(activity);
    final existing = merged[key];
    if (existing != null) {
      // 已报名优先，保留已报名标记。
      continue;
    }
    merged[key] = (activity: activity, registered: activity.isRegistered);
  }

  final windowEnd = today.add(Duration(days: windowDays + 1));
  final activityCandidates = <(DateTime, HomeUpcomingActivityItem)>[];
  for (final entry in merged.values) {
    final activity = entry.activity;
    final start = activity.activityStartAt;
    final end = activity.activityEndAt;

    if (end != null && end.isBefore(now)) continue;
    if (start == null) continue;

    final isOngoing =
        !now.isBefore(start) && (end == null || !now.isAfter(end));
    if (!isOngoing) {
      if (start.isBefore(now)) continue;
      if (!start.isBefore(windowEnd)) continue;
    }

    activityCandidates.add((
      start,
      HomeUpcomingActivityItem(
        id: activity.id,
        title: activity.title.trim(),
        timeLabel: _formatActivityTime(start, today, isOngoing: isOngoing),
        locationText: activity.location.trim(),
        badgeLabel: entry.registered ? '已报名' : '已订阅',
        isOngoing: isOngoing,
      ),
    ));
  }
  activityCandidates.sort((a, b) => a.$1.compareTo(b.$1));
  final upcomingActivities = activityCandidates
      .take(maxActivities)
      .map((entry) => entry.$2)
      .toList();

  return HomeTodayAgenda(
    upcomingExams: upcomingExams,
    upcomingActivities: upcomingActivities,
  );
}

String _activityKey(SecondClassroomActivity activity) {
  if (activity.id > 0) return 'id:${activity.id}';
  return 'title:${activity.title.trim()}';
}

String _joinLocation(String campus, String room) {
  final c = campus.trim();
  final r = room.trim();
  if (c.isEmpty) return r;
  if (r.isEmpty) return c;
  if (r.contains(c)) return r;
  return '$c $r';
}

String _formatActivityTime(
  DateTime start,
  DateTime today, {
  required bool isOngoing,
}) {
  if (isOngoing) return '进行中';
  final startDay = DateTime(start.year, start.month, start.day);
  final delta = startDay.difference(today).inDays;
  final hh = start.hour.toString().padLeft(2, '0');
  final mm = start.minute.toString().padLeft(2, '0');
  final clock = '$hh:$mm';
  if (delta == 0) return '今天 $clock';
  if (delta == 1) return '明天 $clock';
  return '${start.month}月${start.day}日 $clock';
}
