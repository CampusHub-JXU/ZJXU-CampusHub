import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/semester/semester_calendar.dart';
import '../schedule_cache_snapshot.dart';
import '../schedule_constants.dart';
import '../schedule_model.dart';
import '../schedule_service.dart';
import '../schedule_term_context.dart';
import '../schedule_week_view_model.dart';
import '../widgets/schedule_grid.dart';

class SchedulePageController extends ChangeNotifier {
  SchedulePageController({required this._loggedIn})
    : _termContext = ScheduleService.instance.getCurrentTermContext(),
      _displayWeek = ScheduleService.instance.getCurrentWeek() {
    _term = _termContext.term;
  }

  bool _loggedIn;
  bool _loading = false;
  String? _error;
  String? _infoMessage;
  List<CourseEntry> _courses = [];
  List<CourseChangeRule> _courseChangeRules = const [];
  ScheduleTermContext _termContext;
  late int _term;
  int _displayWeek;
  DateTime? _scheduleUpdatedAt;

  /// 用户手动切换过学期后不再自动识别，避免覆盖用户的选择。
  bool _termOverridden = false;

  final Map<int, ScheduleWeekViewModel> _weekViewModels = {};

  bool get loggedIn => _loggedIn;
  bool get loading => _loading;
  String? get error => _error;
  String? get infoMessage => _infoMessage;
  List<CourseEntry> get courses => _courses;
  List<CourseChangeRule> get courseChangeRules => _courseChangeRules;
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

  void updateLoggedIn(bool loggedIn) {
    if (_loggedIn == loggedIn) return;
    _loggedIn = loggedIn;
    if (!loggedIn) {
      _infoMessage = _courses.isNotEmpty ? '登录状态已失效，请重新登录教务' : null;
    }
    notifyListeners();
  }

  void restoreCachedSnapshot() {
    final snapshot = ScheduleService.instance.preferredSnapshot(
      termContext: activeTermContext,
    );
    if (snapshot == null || !snapshot.hasData) {
      _courses = [];
      _courseChangeRules = const [];
      _scheduleUpdatedAt = null;
      _infoMessage = null;
      _weekViewModels.clear();
      notifyListeners();
      return;
    }

    _applySnapshot(snapshot);
    if (!_loggedIn) {
      _infoMessage = '显示的是本地缓存课表，刷新需要重新登录教务';
    }
    notifyListeners();
  }

  void setDisplayWeek(int week) {
    if (week == _displayWeek) return;
    _displayWeek = week;
    _primeNearbyWeekViewModels(week);
    notifyListeners();
  }

  void switchTerm(int term) {
    if (_term == term) return;
    _termOverridden = true;
    _term = term;
    _displayWeek = currentWeek;
    restoreCachedSnapshot();
    if (_courses.isEmpty && _loggedIn) {
      unawaited(fetchSchedule());
    }
  }

  Future<void> fetchSchedule({bool forceRefresh = false}) async {
    _loading = true;
    if (_courses.isEmpty) {
      _error = null;
    }
    notifyListeners();

    try {
      final result = await ScheduleService.instance.loadScheduleSnapshot(
        termContext: _termOverridden ? activeTermContext : null,
        forceRefresh: forceRefresh,
      );

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
      if (_courses.isEmpty) {
        _error = '获取课表失败，请稍后重试';
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
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

  void onLoginSuccess() {
    _loggedIn = true;
    _error = null;
    _infoMessage = null;
    notifyListeners();
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
