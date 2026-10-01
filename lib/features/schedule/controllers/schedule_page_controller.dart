import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/auth/zhengfang_auth.dart';
import '../../../core/semester/semester_calendar.dart';
import '../schedule_cache_snapshot.dart';
import '../schedule_constants.dart';
import '../schedule_model.dart';
import '../schedule_service.dart';
import '../../../core/semester/schedule_term_context.dart';
import '../schedule_week_view_model.dart';
import '../widgets/schedule_grid.dart';

typedef ScheduleSnapshotLoader = Future<ScheduleLoadResult> Function({
  ScheduleTermContext? termContext,
  String? studentId,
  bool forceRefresh,
});

class SchedulePageController extends ChangeNotifier {
  SchedulePageController({
    required this._loggedIn,
    String? studentId,
    @visibleForTesting this._loader,
  }) : _termContext = ScheduleService.instance.getCurrentTermContext(),
       _displayWeek = ScheduleService.instance.getCurrentWeek() {
    _studentId = _loggedIn ? _normalizeStudentId(studentId) : null;
    _term = _termContext.term;
    if (_studentId != null) {
      _activeAuthRevision = ZhengfangAuth.instance.sessionRevision;
    }
  }

  final ScheduleSnapshotLoader? _loader;

  bool _loggedIn;

  /// 当前**已验证**的教务身份（学号）；未登录或身份不可验证时为 null。
  /// 只有该身份自己的缓存/请求结果才允许展示。
  String? _studentId;

  /// 身份 revision：登录、登出、A→B 切换都会递增，用于丢弃迟到结果。
  int _identityEpoch = 0;
  bool _loading = false;
  String? _error;
  String? _infoMessage;
  List<CourseEntry> _courses = [];
  List<CourseChangeRule> _courseChangeRules = const [];
  ScheduleTermContext _termContext;
  late int _term;
  int _displayWeek;
  DateTime? _scheduleUpdatedAt;

  /// 最近一次教务过期是否由「自动登录已暂停」触发；仅影响未登录引导文案。
  bool _automaticLoginPaused = false;

  /// 用户手动切换过学期后不再自动识别，避免覆盖用户的选择。
  bool _termOverridden = false;

  /// 手动切学期的视图代数：切换后递增，用于丢弃切换前发起的旧学期请求结果
  ///（含 finally 的 loading / 错误 / 提示写回），不阻断新学期的正常刷新。
  int _viewTermEpoch = 0;

  /// 最近一次**结束**的已验证会话（账号 + 该会话的控制器身份代数 + 该会话的
  /// auth `sessionRevision`）。
  ///
  /// 仅用于判定迟到的「自动登录已暂停」是否仍属于当前未登录引导：
  /// 只有发起自该会话的迟到结果才允许写回暂停提示。绑定 auth revision 是
  /// 为了覆盖「同账号成功重登」——此时 owner/身份代数不变，但旧会话的暂停
  /// 已不属于新会话的引导。登录成功或身份不可验证时清空，无法证明关联的
  /// 旧暂停一律保守丢弃。
  ({String owner, int epoch, int authRevision})? _loggedOutSession;

  /// 当前已验证会话对应的 auth `sessionRevision`（由 auth 通知与登录入口维护）。
  /// 同账号重登的通知即使身份 no-op 也会刷新它，使旧会话的暂停归属失效。
  int? _activeAuthRevision;

  final Map<int, ScheduleWeekViewModel> _weekViewModels = {};
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool get loggedIn => _loggedIn;
  bool get loading => _loading;
  String? get error => _error;
  String? get infoMessage => _infoMessage;
  bool get automaticLoginPaused => _automaticLoginPaused;
  List<CourseEntry> get courses => _courses;
  List<CourseChangeNotice> get courseChangeNotices =>
      ScheduleService.instance.buildCourseChangeNotices(
        courses: _courses,
        changeRules: _courseChangeRules,
        termContext: activeTermContext,
      );
  int get term => _term;
  int get displayWeek => _displayWeek;
  DateTime? get scheduleUpdatedAt => _scheduleUpdatedAt;
  int get currentWeek => SemesterCalendar.instance.weekForDate(DateTime.now());

  /// 今天是否还未开学（开学日之前）。
  bool get isBeforeSemesterStart =>
      SemesterCalendar.instance.isBeforeSemesterStart();

  /// 今天是否已超出本学期教学周范围。
  bool get isAfterSemesterEnd => SemesterCalendar.instance.isAfterSemesterEnd();

  /// 是否存在"本周"：未开学或学期已结束时不存在本周，
  /// 课表不应把假期里的今天映射到教学周上。
  bool get hasCurrentWeek => !isBeforeSemesterStart && !isAfterSemesterEnd;
  ScheduleTermContext get activeTermContext =>
      _termContext.copyWith(term: _term);

  /// 已验证身份（学号）；未登录时恒为 null。
  String? get _verifiedOwner =>
      _loggedIn ? _normalizeStudentId(_studentId) : null;

  static String? _normalizeStudentId(String? studentId) {
    final trimmed = studentId?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// 更新登录态与**已验证身份**（学号）。
  ///
  /// 身份变化（含 `isLoggedIn` 一直为 true 的 A→B 切换，以及任何登出）
  /// 都会立即清空旧身份的课程/调课/时间戳/周视图/错误/提示/暂停态，随后
  /// 只采纳新身份自己的本地缓存；[studentId] 为空表示身份不可验证，
  /// 不保留也不恢复任何私有课表。同身份重复调用是 no-op。
  void updateLoggedIn(bool loggedIn, {String? studentId}) {
    final nextStudentId = loggedIn ? _normalizeStudentId(studentId) : null;
    if (_loggedIn == loggedIn && _studentId == nextStudentId) {
      // 同账号成功重登会推进 auth sessionRevision（owner/身份不变）：即使
      // 状态 no-op 也要刷新会话归属，让旧会话的迟到暂停失效。
      if (loggedIn && nextStudentId != null) {
        _activeAuthRevision = ZhengfangAuth.instance.sessionRevision;
      }
      return;
    }

    final previousOwner = _verifiedOwner;
    final previousEpoch = _identityEpoch;

    _loggedIn = loggedIn;
    _studentId = nextStudentId;
    _identityEpoch++;
    _resetAccountScopedState();
    if (nextStudentId != null) {
      // 新会话开始：旧会话的迟到暂停不再属于当前引导。
      _activeAuthRevision = ZhengfangAuth.instance.sessionRevision;
      _loggedOutSession = null;
      _adoptCachedSnapshotFor(nextStudentId);
    } else if (!_loggedIn && previousOwner != null) {
      // 记录刚刚结束的会话（账号 + 身份代数 + auth revision），供迟到的
      // 暂停提示做归属判定。
      _loggedOutSession = (
        owner: previousOwner,
        epoch: previousEpoch,
        authRevision:
            _activeAuthRevision ?? ZhengfangAuth.instance.sessionRevision,
      );
      _activeAuthRevision = null;
    } else {
      // 身份不可验证或本就未登录：无法证明关联，保守清空。
      _loggedOutSession = null;
      _activeAuthRevision = null;
    }
    notifyListeners();
  }

  void restoreCachedSnapshot() {
    _resetAccountScopedState();
    final owner = _verifiedOwner;
    if (owner != null) {
      _adoptCachedSnapshotFor(owner);
    }
    notifyListeners();
  }

  /// 采纳 [owner] 的本地缓存快照；调用方必须已清空旧身份数据。
  /// 身份不可验证时不读私有缓存，避免经旧 `lastStudentId` 复活他人课表。
  void _adoptCachedSnapshotFor(String owner) {
    final snapshot = ScheduleService.instance.preferredSnapshot(
      termContext: activeTermContext,
      studentId: owner,
    );
    if (snapshot == null || !snapshot.hasData) return;
    _applySnapshot(snapshot);
  }

  /// 清除只属于旧身份的状态；迟到结果由身份 revision 拦截，不能经此复活。
  void _resetAccountScopedState() {
    _courses = [];
    _courseChangeRules = const [];
    _scheduleUpdatedAt = null;
    _weekViewModels.clear();
    _error = null;
    _infoMessage = null;
    _automaticLoginPaused = false;
    _loading = false;
  }

  void setDisplayWeek(int week) {
    if (week == _displayWeek) return;
    _displayWeek = week;
    // 周数变化不驱动任何可见 UI（每页网格的角标取自各自的 view model），
    // 因此不 notifyListeners，避免在拖拽/settle 动画帧内触发全页重建。
    _scheduleNearbyWeekPrime(week);
  }

  /// 帧末预热邻周 view model：把同步构建挪出滑动动画帧，
  /// 供下一次滑动直接命中缓存（weekViewModelFor 本身可惰性兜底）。
  void _scheduleNearbyWeekPrime(int centerWeek) {
    if (_disposed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _primeNearbyWeekViewModels(centerWeek);
    });
  }

  void switchTerm(int term) {
    if (_term == term) return;
    _termOverridden = true;
    _term = term;
    _displayWeek = currentWeek;
    // 切换视图代数：此前发起的旧学期请求一律失效，新学期的 fetch 会捕获新值。
    _viewTermEpoch++;
    restoreCachedSnapshot();
    if (_courses.isEmpty && _loggedIn) {
      unawaited(fetchSchedule());
    }
  }

  Future<void> fetchSchedule({bool forceRefresh = false}) async {
    final epoch = _identityEpoch;
    final termEpoch = _viewTermEpoch;
    final owner = _verifiedOwner;
    // 本次请求归属的 auth 会话；只用于暂停提示归属，不参与课程结果采纳。
    final authRevision = ZhengfangAuth.instance.sessionRevision;
    _loading = true;
    if (_courses.isEmpty) {
      _error = null;
    }
    notifyListeners();

    try {
      final loader = _loader ?? ScheduleService.instance.loadScheduleSnapshot;
      final result = await loader(
        termContext: _termOverridden ? activeTermContext : null,
        studentId: owner,
        forceRefresh: forceRefresh,
      );
      if (_isStaleForCurrentView(result, epoch, termEpoch)) {
        _discardStaleResult(
          result,
          owner: owner,
          epoch: epoch,
          authRevision: authRevision,
        );
        return;
      }

      _automaticLoginPaused = result.automaticLoginPaused;

      _adoptTermContextIfNeeded(result);
      _infoMessage = null;

      final snapshot = result.snapshot;
      if (snapshot != null && snapshot.hasData) {
        _applySnapshot(snapshot);
        _error = null;
      }

      if (result.message != null) {
        if (_courses.isNotEmpty) {
          _infoMessage = result.message;
        } else {
          _error = result.message;
        }
      } else if (!_loggedIn && _courses.isNotEmpty) {
        _infoMessage = '显示的是本地缓存课表，刷新需要重新登录教务';
      }
    } catch (_) {
      if (!_isCurrentView(epoch, termEpoch)) return;
      if (_courses.isEmpty) {
        _error = '获取课表失败，请稍后重试';
      }
    } finally {
      if (_isCurrentView(epoch, termEpoch)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// 本次请求发起后身份或手动切换的学期是否已经变化。
  bool _isCurrentView(int epoch, int termEpoch) =>
      epoch == _identityEpoch && termEpoch == _viewTermEpoch;

  /// 结果是否已经不属于当前视图：身份 revision 或手动学期已变化，
  /// 或返回的快照不是当前已验证 owner 的（含当前无身份）。
  bool _isStaleForCurrentView(
    ScheduleLoadResult result,
    int epoch,
    int termEpoch,
  ) {
    if (!_isCurrentView(epoch, termEpoch)) return true;
    final snapshot = result.snapshot;
    if (snapshot == null || !snapshot.hasData) return false;
    final owner = _verifiedOwner;
    return owner == null || snapshot.studentId != owner;
  }

  /// 丢弃迟到结果：不写回旧身份的课程/调课/时间戳/错误/信息。
  ///
  /// 唯一例外是「自动登录已暂停」——它描述的是当前未登录引导而非旧身份数据。
  /// 只有当结果来自**当前引导关联的那次已结束会话**（发起时的已验证 owner、
  /// 身份代数与 auth `sessionRevision` 都吻合，且当前仍未登录）时才接纳；
  /// 无法证明关联时保守丢弃，避免旧账号/同账号旧会话的迟到暂停覆盖当前引导。
  /// 课程快照的采纳不受 auth revision 约束（见 `_isStaleForCurrentView`），
  /// 同 owner 在新 revision 下重新查询的合法结果仍会正常展示。
  void _discardStaleResult(
    ScheduleLoadResult result, {
    required String? owner,
    required int epoch,
    required int authRevision,
  }) {
    if (_disposed || _loggedIn || _automaticLoginPaused) return;
    if (!result.automaticLoginPaused) return;
    final session = _loggedOutSession;
    if (session == null || owner == null) return;
    if (owner != session.owner ||
        epoch != session.epoch ||
        authRevision != session.authRevision) {
      return;
    }
    _automaticLoginPaused = true;
    notifyListeners();
  }

  /// 未手动切换学期时，采纳服务端解析出的实际学期
  ///（自动识别修正学年/学期，或假期回退到上一学期）。
  void _adoptTermContextIfNeeded(ScheduleLoadResult result) {
    if (_termOverridden) return;
    final effective = result.effectiveTermContext;
    if (effective == null || effective == _termContext) return;
    _termContext = effective;
    _term = effective.term;
    _displayWeek = currentWeek;
  }

  /// 手动登录成功：只采纳**明确且与当前教务会话一致**的已验证身份。
  ///
  /// 返回 `true` 表示身份已验证并已按该身份接纳（调用方随后可强制刷新）；
  /// 返回 `false` 表示 [studentId] 缺失或与 [ZhengfangAuth.currentStudentId]
  /// 不一致：清空旧 owner 的课程/规则/状态、不恢复任何缓存、也不视为已登录，
  /// 调用方不得据此对旧 owner 发起刷新请求。
  bool onLoginSuccess({String? studentId}) {
    final requested = _normalizeStudentId(studentId);
    final auth = ZhengfangAuth.instance;
    final currentOwner = auth.isLoggedIn
        ? _normalizeStudentId(auth.currentStudentId)
        : null;

    if (requested == null || requested != currentOwner) {
      _loggedIn = false;
      _studentId = null;
      _identityEpoch++;
      _resetAccountScopedState();
      // 身份不可验证：无法证明任何旧会话与当前引导的关联，保守清空。
      _loggedOutSession = null;
      _activeAuthRevision = null;
      notifyListeners();
      return false;
    }

    if (!_loggedIn || requested != _studentId) {
      _loggedIn = true;
      _studentId = requested;
      _identityEpoch++;
      _resetAccountScopedState();
      _adoptCachedSnapshotFor(requested);
    }
    // 已按新会话登录：旧会话的迟到暂停不再属于当前引导。
    _loggedOutSession = null;
    _activeAuthRevision = ZhengfangAuth.instance.sessionRevision;
    _error = null;
    _infoMessage = null;
    // 手动登录成功即重新武装自动登录，清除暂停文案。
    _automaticLoginPaused = false;
    notifyListeners();
    return true;
  }

  ScheduleWeekViewModel weekViewModelFor(int week) {
    return _weekViewModels.putIfAbsent(week, () => _buildWeekViewModel(week));
  }

  void _applySnapshot(ScheduleCacheSnapshot snapshot) {
    _courses = snapshot.courses;
    _courseChangeRules = snapshot.changeRules;
    _scheduleUpdatedAt = snapshot.lastUpdatedAt;
    _weekViewModels.clear();
    _primeNearbyWeekViewModels(_displayWeek);
  }

  void _primeWeekViewModel(int week) {
    if (_courses.isEmpty || week < 1 || week > scheduleWeekCount) return;
    _weekViewModels.putIfAbsent(week, () => _buildWeekViewModel(week));
  }

  void _primeNearbyWeekViewModels(int centerWeek) {
    for (final week in [centerWeek - 1, centerWeek, centerWeek + 1]) {
      _primeWeekViewModel(week);
    }
  }

  ScheduleWeekViewModel _buildWeekViewModel(int week) {
    final effectiveWeekCourses = ScheduleService.instance
        .buildEffectiveWeekCourses(
          courses: _courses,
          week: week,
          changeRules: _courseChangeRules,
          termContext: activeTermContext,
        );

    final currentWeekCoursesByDay = <int, List<CourseEntry>>{
      for (int day = 1; day <= 7; day++) day: <CourseEntry>[],
    };
    for (final course in effectiveWeekCourses) {
      currentWeekCoursesByDay[course.weekday]?.add(course);
    }

    final otherWeekCoursesByDay = <int, List<CourseEntry>>{
      for (int day = 1; day <= 7; day++) day: <CourseEntry>[],
    };
    for (final course in _courses) {
      if (course.isInWeek(week)) {
        continue;
      }
      otherWeekCoursesByDay[course.weekday]?.add(course);
    }

    final days = <int, ScheduleDayCourses>{};
    for (int day = 1; day <= 7; day++) {
      final dayCurrent = ScheduleGrid.mergeAdjacentCourses(
        currentWeekCoursesByDay[day]!,
      );
      final dayOther = ScheduleGrid.deduplicateBySlot(
        otherWeekCoursesByDay[day]!,
        dayCurrent,
      );
      days[day] = ScheduleDayCourses(
        currentWeekCourses: dayCurrent,
        otherWeekCourses: dayOther,
      );
    }
    return ScheduleWeekViewModel(week: week, days: days);
  }
}
