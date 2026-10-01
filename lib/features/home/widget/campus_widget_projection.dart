import '../../../core/notice/notice_sync_store.dart';
import '../../../core/semester/semester_calendar.dart';
import '../../../core/theme/personalization_controller.dart';
import '../campus_snapshot_coordinator.dart';
import '../home_presentation_resolver.dart';
import '../models/home_presentation.dart';
import '../models/home_snapshot.dart';

/// 桌面组件展示投影（PRD §12/§13）。
///
/// 只包含展示文本与时间戳，**不含任何凭据**；由 CampusSnapshot 派生，Home、
/// Widget、系统入口共享同一份数据。
class CampusWidgetProjection {
  const CampusWidgetProjection({
    required this.generatedAt,
    required this.weekLabel,
    required this.heroHeadline,
    required this.todayCourses,
    required this.hasTodayCourses,
    this.todayTitle = '今天',
    this.heroTimeText,
    this.heroCourseName,
    this.heroLocationText,
    this.nextExamCourseName,
    this.nextExamTimeText,
    this.nextExamLocationText,
    required this.campusCardBalance,
    required this.hasCampusCardData,
    required this.dormElectricity,
    required this.hasElectricityData,
    required this.unreadNoticeCount,
  });

  final DateTime generatedAt;
  final String weekLabel;

  final String heroHeadline;
  final String? heroTimeText;
  final String? heroCourseName;
  final String? heroLocationText;

  /// 今日课程：[{timeText, courseName, locationText, isOngoing}]
  final List<Map<String, Object?>> todayCourses;
  final bool hasTodayCourses;

  /// 今日课程段标题：'今天'，或次日预览形态的 '明天' / '开学首日'（原生中组件据此命名）。
  final String todayTitle;

  final String? nextExamCourseName;
  final String? nextExamTimeText;
  final String? nextExamLocationText;

  final String campusCardBalance;
  final bool hasCampusCardData;
  final String dormElectricity;
  final bool hasElectricityData;

  final int unreadNoticeCount;

  Map<String, Object?> toMap() => {
    'generatedAt': generatedAt.toIso8601String(),
    'weekLabel': weekLabel,
    'heroHeadline': heroHeadline,
    'heroTimeText': heroTimeText,
    'heroCourseName': heroCourseName,
    'heroLocationText': heroLocationText,
    'todayCourses': todayCourses,
    'hasTodayCourses': hasTodayCourses,
    'todayTitle': todayTitle,
    'nextExamCourseName': nextExamCourseName,
    'nextExamTimeText': nextExamTimeText,
    'nextExamLocationText': nextExamLocationText,
    'campusCardBalance': campusCardBalance,
    'hasCampusCardData': hasCampusCardData,
    'dormElectricity': dormElectricity,
    'hasElectricityData': hasElectricityData,
    'unreadNoticeCount': unreadNoticeCount,
  };

  static CampusWidgetProjection fromPresentation(
    HomePresentation presentation, {
    required DateTime generatedAt,
    required int unreadNoticeCount,
  }) {
    final exam = presentation.today.exams.isEmpty
        ? null
        : presentation.today.exams.first;
    return CampusWidgetProjection(
      generatedAt: generatedAt,
      weekLabel: presentation.weekLabel,
      heroHeadline: presentation.hero.headline,
      heroTimeText: presentation.hero.timeText,
      heroCourseName: presentation.hero.courseName,
      heroLocationText: presentation.hero.locationText,
      todayCourses: [
        for (final course in presentation.today.courses)
          {
            'timeText': course.timeText,
            'courseName': course.courseName,
            'locationText': course.locationText,
            'isOngoing': course.isOngoing,
          },
      ],
      hasTodayCourses: presentation.today.courses.isNotEmpty,
      todayTitle: presentation.today.title,
      nextExamCourseName: exam?.courseName,
      nextExamTimeText: exam?.timeText,
      nextExamLocationText: exam?.locationText,
      campusCardBalance: presentation.status.campusCardBalance,
      hasCampusCardData: presentation.status.hasCampusCardData,
      dormElectricity: presentation.status.dormElectricity,
      hasElectricityData: presentation.status.hasElectricityData,
      unreadNoticeCount: unreadNoticeCount,
    );
  }
}

/// 从当前缓存态构建投影（仅读缓存，不发起网络请求）。
CampusWidgetProjection buildCampusWidgetProjection({DateTime? now}) {
  final at = now ?? DateTime.now();
  final coordinator = CampusSnapshotCoordinator.instance;
  final restore = coordinator.restore(at);
  final calendar = SemesterCalendar.instance;
  final snapshot = HomeSnapshot(
    now: at,
    courseLoggedIn: restore.courseLoggedIn,
    hasScheduleCache: restore.hasScheduleCache,
    courses: restore.scheduleSnapshot?.courses ?? const [],
    changeRules: restore.scheduleSnapshot?.changeRules ?? const [],
    isBeforeSemesterStart: calendar.isBeforeSemesterStart(at),
    isAfterSemesterEnd: calendar.isAfterSemesterEnd(at),
    currentWeek: calendar.weekForDate(at),
    semesterStartDate: calendar.semesterStartDate.value,
    campusCardBalance: restore.campusCardBalance,
    dormElectricity: restore.dormElectricity,
    nextExam: restore.nextExam,
  );
  final presentation = resolveHomePresentation(
    snapshot,
    fullDayCourses:
        PersonalizationController.instance.fullDayCoursesEnabled.value,
  );
  return CampusWidgetProjection.fromPresentation(
    presentation,
    generatedAt: at,
    unreadNoticeCount: NoticeSyncStore.instance.unreadSummary.value.count,
  );
}
