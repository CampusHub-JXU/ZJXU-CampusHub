/// Hero 状态类型，决定 Primary Status Hero 的信息形态与视觉重点。
enum HomeHeroKind {
  /// 正在上课：显示下课时间。
  currentCourse,

  /// 今天还有课：显示倒计时文案（如「42 分钟后上课」）。
  nextCourseToday,

  /// 24 小时内有考试。
  examSoon,

  /// 未开学：显示开学倒计时。
  beforeSemester,

  /// 本学期教学周已全部结束。
  semesterOver,

  /// 今天没有剩余安排（可能展示下一节课预告）。
  noCourseToday,

  /// 未登录且无本地课表缓存。
  loggedOut,
}

/// Hero 卡片要展示的一条完整状态信息。
class HomeHeroPresentation {
  const HomeHeroPresentation({
    required this.kind,
    required this.headline,
    this.timeText,
    this.courseName,
    this.locationText,
    this.lessonText,
  });

  final HomeHeroKind kind;

  /// 状态大字，如「42 分钟后上课」「正在上课」「距离开学还有 9 天」。
  final String headline;

  /// 时间元信息，如「09:45」「11:55 下课」「下一节：明天 08:00」。
  final String? timeText;

  /// 课程 / 考试名称。
  final String? courseName;

  /// 地点（校区 + 教室合并后的文本）。
  final String? locationText;

  /// 节次文本，如「第 3-5 节」。
  final String? lessonText;
}

/// 事件横幅类型。仅在真正需要用户处理时出现，平时整块消失。
enum HomeAlertKind { examSoon, lowElectricity, lowBalance }

/// 单条事件提醒：图标 + 文案 + 可选跳转。
class HomeAlertPresentation {
  const HomeAlertPresentation({
    required this.kind,
    required this.message,
    required this.routeName,
  });

  final HomeAlertKind kind;
  final String message;

  /// 点击横幅跳转的路由名。
  final String routeName;
}

/// 高频资产状态（校园卡 + 宿舍电费），Status Strip 的数据源。
class HomeStatusPresentation {
  const HomeStatusPresentation({
    required this.campusCardBalance,
    required this.dormElectricity,
    required this.hasCampusCardData,
    required this.hasElectricityData,
    required this.lowBalance,
    required this.lowElectricity,
  });

  /// 格式化后的余额文本（'--' 表示未获取）。
  final String campusCardBalance;

  /// 格式化后的电费文本（'--' 表示未获取）。
  final String dormElectricity;

  final bool hasCampusCardData;
  final bool hasElectricityData;

  /// 余额 ≤ ¥20 时触发（数据缺失时不判定）。
  final bool lowBalance;

  /// 电量 ≤ 10 度时触发（数据缺失时不判定）。
  final bool lowElectricity;
}

/// Today Section 中的一行课程。
class HomeTodayCourseRow {
  const HomeTodayCourseRow({
    required this.timeText,
    required this.lessonText,
    required this.courseName,
    required this.locationText,
    required this.isOngoing,
  });

  /// 上课开始时间，如「09:45」。
  final String timeText;

  /// 节次文本，如「第 3-5 节」。
  final String lessonText;
  final String courseName;
  final String locationText;

  /// 当前正在上的课，行尾追加「进行中」标记。
  final bool isOngoing;
}

/// Today Section 中的一行考试。
class HomeTodayExamRow {
  const HomeTodayExamRow({
    required this.timeText,
    required this.courseName,
    required this.locationText,
  });

  /// 考试时间段，如「09:00-11:00」；无时间时为「时间待定」。
  final String timeText;
  final String courseName;
  final String locationText;
}

/// Today Section：当天剩余课程 + 今日考试。
class HomeTodayPresentation {
  const HomeTodayPresentation({required this.courses, required this.exams});

  final List<HomeTodayCourseRow> courses;
  final List<HomeTodayExamRow> exams;

  bool get isEmpty => courses.isEmpty && exams.isEmpty;
}

/// 首页完整展示层模型：由 [HomeSnapshot] 经纯函数 resolver 派生。
class HomePresentation {
  const HomePresentation({
    required this.hero,
    required this.alert,
    required this.status,
    required this.today,
    required this.weekLabel,
  });

  final HomeHeroPresentation hero;

  /// 事件提醒；无事件时为 null，横幅整块不渲染。
  final HomeAlertPresentation? alert;
  final HomeStatusPresentation status;
  final HomeTodayPresentation today;

  /// 周次标签：「第 N 周」/「未开学」/「学期已结束」，
  /// 供首页顶部环境行使用。
  final String weekLabel;
}
