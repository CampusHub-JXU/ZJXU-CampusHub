import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/semester/semester_calendar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import 'controllers/schedule_page_controller.dart';
import 'schedule_constants.dart';
import 'widgets/schedule_change_sheet.dart';
import 'widgets/schedule_grid.dart';
import 'widgets/schedule_info_banner.dart';
import '../../shared/widgets/app_app_bar.dart';

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late final SchedulePageController _controller;
  late final PageController _weekPageController;
  bool _loginPromptShown = false;
  bool _loginPromptInFlight = false;

  @override
  void initState() {
    super.initState();
    final auth = ZhengfangAuth.instance;
    _controller = SchedulePageController(
      loggedIn: auth.isLoggedIn,
      studentId: auth.currentStudentId,
    );
    _weekPageController = PageController(
      initialPage: _controller.displayWeek - 1,
    );
    ZhengfangAuth.instance.addListener(_handleAuthChanged);
    _controller.restoreCachedSnapshot();
    if (_controller.loggedIn || _controller.courses.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_controller.fetchSchedule());
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt());
      });
    }
  }

  @override
  void dispose() {
    ZhengfangAuth.instance.removeListener(_handleAuthChanged);
    _weekPageController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleAuthChanged() {
    if (!mounted) return;
    final auth = ZhengfangAuth.instance;
    final nextLoggedIn = auth.isLoggedIn;
    final becameLoggedOut = _controller.loggedIn && !nextLoggedIn;

    // 身份（含 A→B 且 isLoggedIn 一直为 true 的切换）变化必须传给
    // controller，否则旧账号课表会留在页面上；同身份重复通知是 no-op。
    _controller.updateLoggedIn(
      nextLoggedIn,
      studentId: nextLoggedIn ? auth.currentStudentId : null,
    );

    if (becameLoggedOut) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
    }
  }

  void _onWeekPageChanged(int index) {
    _controller.setDisplayWeek(index + 1);
  }

  Future<void> _refreshScheduleOrLogin() async {
    if (!_controller.loggedIn) {
      if (!mounted) return;
      final loggedIn = await context.pushNamed<bool>('academic-system-login');
      if (!mounted || loggedIn != true) return;
      _onLoginSuccess();
      return;
    }
    await _controller.fetchSchedule(forceRefresh: true);
  }

  void _onLoginSuccess() {
    // 弹窗/路由报告成功但教务身份尚未就绪时，控制器会清空旧 owner 并返回
    // false：这里不得把它当作成功刷新，也绝不带旧 owner 发起请求。
    final accepted = _controller.onLoginSuccess(
      studentId: ZhengfangAuth.instance.currentStudentId,
    );
    if (!accepted) return;
    unawaited(_controller.fetchSchedule(forceRefresh: true));
  }

  Future<void> _presentLoginPrompt({bool force = false}) async {
    if (!mounted || _loginPromptInFlight || _controller.loggedIn) return;
    if (!force && _loginPromptShown) return;

    _loginPromptShown = true;
    _loginPromptInFlight = true;
    final loggedIn = await showAcademicSystemLoginModal(context);
    _loginPromptInFlight = false;
    if (!mounted || !loggedIn) return;
    _onLoginSuccess();
  }

  Future<void> _showCourseChangeSheet() async {
    final notices = _controller.courseChangeNotices;
    if (notices.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.68,
          minChildSize: 0.38,
          maxChildSize: 0.94,
          builder: (context, scrollController) {
            return ScheduleChangeSheet(
              notices: notices,
              displayWeek: _controller.displayWeek,
              scrollController: scrollController,
            );
          },
        );
      },
    );
  }

  Widget _buildLoginBody() => buildScheduleLoginView(
    automaticLoginPaused: _controller.automaticLoginPaused,
    onAction: () => _presentLoginPrompt(force: true),
  );

  Widget _buildScheduleBody() {
    if (_controller.loading && _controller.courses.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.error != null && _controller.courses.isEmpty) {
      return AppErrorView(
        message: _controller.error,
        onRetry: _refreshScheduleOrLogin,
      );
    }
    if (_controller.courses.isEmpty) {
      return AppEmptyView(
        title: '暂无课表数据',
        icon: Icons.calendar_month_outlined,
        actionLabel: _controller.loggedIn ? '刷新课表' : null,
        onAction: _controller.loggedIn ? _refreshScheduleOrLogin : null,
      );
    }

    return Column(
      children: [
        if (_controller.loading) const LinearProgressIndicator(minHeight: 2),
        ScheduleInfoBanner(
          message: _bannerMessage(),
          updatedAt: _controller.scheduleUpdatedAt,
          loggedIn: _controller.loggedIn,
        ),
        Expanded(child: _buildWeekPager()),
      ],
    );
  }

  /// 假期/开学前的状态提示，非教学周时说明真实的日期状态。
  String? get _termStatusMessage {
    if (_controller.isBeforeSemesterStart) {
      final start = SemesterCalendar.instance.semesterStartDate.value;
      final weekOne = SemesterCalendar.instance.weekOneStartDate;
      return '未开学 · ${start.month}月${start.day}日开学，第1周自${weekOne.month}月${weekOne.day}日（周一）起算';
    }
    if (_controller.isAfterSemesterEnd) {
      return '本学期教学周已结束';
    }
    return null;
  }

  String? _bannerMessage() {
    final parts = <String>[?_termStatusMessage, ?_controller.infoMessage];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  Widget _buildWeekPager() {
    return PageView.builder(
      controller: _weekPageController,
      physics: const ClampingScrollPhysics(),
      itemCount: scheduleWeekCount,
      onPageChanged: _onWeekPageChanged,
      itemBuilder: (context, index) {
        final week = index + 1;
        final weekViewModel = _controller.weekViewModelFor(week);
        return RepaintBoundary(
          child: ScheduleGrid(
            key: ValueKey('week-grid-$week'),
            weekViewModel: weekViewModel,
            actualCurrentWeek: _controller.hasCurrentWeek
                ? _controller.currentWeek
                : null,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppAppBar(
            title: const Text('课表'),
            actions: (_controller.loggedIn || _controller.courses.isNotEmpty)
                ? [
                    if (_controller.courseChangeNotices.isNotEmpty)
                      IconButton(
                        tooltip: '调课提醒',
                        onPressed: _showCourseChangeSheet,
                        icon: Badge(
                          label: Text(
                            _controller.courseChangeNotices.length > 99
                                ? '99+'
                                : '${_controller.courseChangeNotices.length}',
                          ),
                          child: const Icon(Icons.swap_horiz_rounded),
                        ),
                      ),
                    PopupMenuButton<int>(
                      icon: const Icon(Icons.calendar_today),
                      tooltip: '切换学期',
                      onSelected: (value) {
                        _controller.switchTerm(value);
                        if (_weekPageController.hasClients) {
                          _weekPageController.jumpToPage(
                            _controller.displayWeek - 1,
                          );
                        }
                        unawaited(_controller.fetchSchedule());
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 3, child: Text('第一学期')),
                        PopupMenuItem(value: 12, child: Text('第二学期')),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _refreshScheduleOrLogin,
                    ),
                  ]
                : null,
          ),
          body: (_controller.loggedIn || _controller.courses.isNotEmpty)
              ? _buildScheduleBody()
              : _buildLoginBody(),
        );
      },
    );
  }
}

/// 未登录引导视图；[automaticLoginPaused] 为 true 时切换为「需要手动登录」文案。
@visibleForTesting
Widget buildScheduleLoginView({
  required bool automaticLoginPaused,
  required VoidCallback onAction,
}) => AuthRequiredView(
  title: automaticLoginPaused ? '需要手动登录' : '登录后查看课表',
  message: automaticLoginPaused
      ? '自动登录已暂停（多次登录失败），请手动登录一次；登录成功后会自动重新开启自动登录。'
      : '课表刷新依赖教务系统会话，登录后即可同步最新课程数据。',
  buttonLabel: '登录教务系统',
  onAction: onAction,
  icon: Icons.calendar_month_outlined,
);
