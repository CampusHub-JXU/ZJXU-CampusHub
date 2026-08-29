import '../../exam/exam_model.dart';
import '../../schedule/schedule_change_rule.dart';
import '../../schedule/schedule_model.dart';
import 'home_presentation.dart';

/// 首页展示层快照。
///
/// 把 HomePage 持有的业务数据（课表缓存、考试、余额）与日历上下文聚合成
/// 一个纯数据对象；展示层如何组织（Hero 优先级、事件、Today/Week 摘要）
/// 全部交给纯函数 resolver 派生，二者可以分开测试。
class HomeSnapshot {
  const HomeSnapshot({
    required this.now,
    required this.courseLoggedIn,
    required this.hasScheduleCache,
    required this.courses,
    required this.changeRules,
    required this.isBeforeSemesterStart,
    required this.isAfterSemesterEnd,
    required this.currentWeek,
    required this.semesterStartDate,
    required this.campusCardBalance,
    required this.dormElectricity,
    required this.learningEntries,
    this.nextExam,
  });

  /// 展示层判定基准时间；resolver 内不得再取 [DateTime.now]。
  final DateTime now;

  /// 教务可见性：已登录或本地存在课表缓存时视为可展示课程信息。
  final bool courseLoggedIn;
  final bool hasScheduleCache;
  final List<CourseEntry> courses;
  final List<CourseChangeRule> changeRules;

  /// 日历上下文（由 SemesterCalendar 在快照构建时求值）。
  final bool isBeforeSemesterStart;
  final bool isAfterSemesterEnd;
  final int currentWeek;
  final DateTime semesterStartDate;

  /// 格式化后的校园卡余额文本（'--' 表示未获取）。
  final String campusCardBalance;

  /// 格式化后的宿舍电费文本（'--' 表示未获取）。
  final String dormElectricity;
  final ExamEntry? nextExam;

  /// 功能入口目录中配置的首页学习入口（第二课堂 / 图书馆等）。
  final List<HomeQuickActionPresentation> learningEntries;
}
