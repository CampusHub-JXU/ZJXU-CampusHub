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

  /// 今天没有剩余安排且近期无课（「近期无课」纯文字态；近期有课时
  /// 由 [nextCourseUpcoming] 以课程大字承接下一节课）。
  noCourseToday,

  /// 今天没有剩余安排但近期有课：下一节课升级为课程大字主体，
  /// 「今天没课」并入 kicker，日期标签（如「明天 08:00」）并入时间行。
  nextCourseUpcoming,

  /// 假期：今天是法定节假日或整天停课，且明天也不上课；显示轻松的
  /// 只放假的文案，不提示恢复上课日（明天有课时回到 [nextCourseUpcoming]）。
  holiday,

  /// 未登录且无本地课表缓存。
  loggedOut,
}

/// Hero 卡片要展示的一条完整状态信息。
class HomeHeroPresentation {
  const HomeHeroPresentation({
    required this.kind,
    required this.headline,
    this.kicker,
    this.timeText,
    this.courseName,
    this.locationText,
    this.lessonText,
  });

  final HomeHeroKind kind;

  /// 覆盖默认 kicker 的文案（如假期态的「国庆节 · 放假中」）；
  /// 为 null 时由 Hero 组件按 [kind] 取默认值。
  final String? kicker;

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
enum HomeAlertKind {
  examSoon,
  lowElectricity,

  /// 已停用：校园卡低余额不再触发首页强调，resolver 不会产生该类型；
  /// 保留枚举值仅为兼容既有构造与测试。
  lowBalance,
}

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

  /// 保留兼容字段，恒为 false：校园卡低余额不再触发首页强调
  /// （资产行红字与事件横幅均已停用）。
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
    this.isDone = false,
  });

  /// 上课开始时间，如「09:45」。
  final String timeText;

  /// 节次文本，如「第 3-5 节」。
  final String lessonText;
  final String courseName;
  final String locationText;

  /// 当前正在上的课，行尾追加「进行中」标记。
  final bool isOngoing;

  /// 已结束的课程标记；Today 列表目前不会放入已结束的行。
  final bool isDone;
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

/// Today Section：当天剩余课程 + 今日考试；今天没有剩余安排时降级为
/// 「次日预览」形态（开学前 = 开学首日课表，学期中 = 明天/下一个有课日），
/// 标题由 [title] 区分，避免假期/晚间首页上半屏空置。
class HomeTodayPresentation {
  const HomeTodayPresentation({
    required this.courses,
    required this.exams,
    this.title = '今天',
    this.isPreview = false,
    this.isCollapsed = false,
    this.isFullDay = false,
  });

  /// 段落标题：'今天'，或预览形态如 '开学首日' / '明天'；折叠形态不渲染标题。
  final String title;

  /// 是否为次日预览形态：预览是未来安排的轻量提示，渲染上比实时的
  /// 「今天」列表低一档（字号更小、更收敛）。
  final bool isPreview;

  /// 折叠形态：Hero 已用课程大字展示命中日首课，本段降为单行
  /// 「之后还有 N 门」摘要，避免次日列表与 Hero 抢视觉权重。
  /// [courses] 为剔除首课后的余下课程（供摘要取「下一门」与总数），
  /// 不渲染标题与课程行；余下为空时整段不出现。
  final bool isCollapsed;

  /// 全天形态（首页个性化开关）：行数上限比默认形态宽（6 条）；已结束的课
  /// 不进列表。
  final bool isFullDay;

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

  /// 周次标签：「第 N 周」/「学期已结束」；未开学时为空串
  /// （环境行省略状态段，避免与 Hero 开学倒计时重复）。
  final String weekLabel;
}
