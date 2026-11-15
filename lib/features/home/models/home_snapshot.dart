import '../../../core/academic/exam_model.dart';
import '../../../core/academic/schedule_change_rule.dart';
import '../../../core/academic/schedule_date_override.dart';
import '../../../core/academic/schedule_model.dart';
import 'home_asset_state.dart';

/// 首页展示层快照。
///
/// 把 HomePage 持有的业务数据（课表缓存、考试、余额）与日历上下文聚合成
/// 一个纯数据对象；展示层如何组织（Hero 优先级、事件、Today 摘要）
/// 全部交给纯函数 resolver 派生，二者可以分开测试。
class HomeSnapshot {
  const HomeSnapshot({
    required this.now,
    required this.courseLoggedIn,
    required this.hasScheduleCache,
    required this.courses,
    required this.changeRules,
    this.dateOverrides = const [],
    required this.isBeforeSemesterStart,
    required this.isAfterSemesterEnd,
    required this.currentWeek,
    required this.semesterStartDate,
    required this.campusCardBalance,
    required this.dormElectricity,
    this.campusCardAsset,
    this.electricityAsset,
    this.nextExam,
  });

  /// 展示层判定基准时间；resolver 内不得再取 [DateTime.now]。
  final DateTime now;

  /// 教务可见性：已登录或本地存在课表缓存时视为可展示课程信息。
  final bool courseLoggedIn;
  final bool hasScheduleCache;
  final List<CourseEntry> courses;
  final List<CourseChangeRule> changeRules;

  /// 用户的特定日期课程编辑（课表页本地覆盖）；随课表缓存快照透传，
  /// 首页有效课与桌面组件投影与课表页保持同一展开口径。
  final List<ScheduleDateOverride> dateOverrides;

  /// 日历上下文（由 SemesterCalendar 在快照构建时求值）。
  final bool isBeforeSemesterStart;
  final bool isAfterSemesterEnd;
  final int currentWeek;
  final DateTime semesterStartDate;

  /// 格式化后的校园卡余额文本（'--' 表示未获取）。
  final String campusCardBalance;

  /// 格式化后的宿舍电费文本（'--' 表示未获取）。
  final String dormElectricity;

  /// 校园卡余额的独立获取状态模型（首页资产行使用）。静态投影 / 示例等
  /// 旧调用方可省略，由 resolver 按 [campusCardBalance] 字符串回退。
  final HomeAssetState? campusCardAsset;

  /// 宿舍电费的独立获取状态模型。
  final HomeAssetState? electricityAsset;

  final ExamEntry? nextExam;
}
