import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import 'controllers/schedule_page_controller.dart';
import 'schedule_constants.dart';
import 'widgets/schedule_change_sheet.dart';
import 'widgets/schedule_grid.dart';
import 'widgets/schedule_info_banner.dart';

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
    _controller = SchedulePageController(
      loggedIn: ZhengfangAuth.instance.isLoggedIn,
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
    final nextLoggedIn = ZhengfangAuth.instance.isLoggedIn;
    if (!mounted || nextLoggedIn == _controller.loggedIn) return;

    _controller.updateLoggedIn(nextLoggedIn);

    if (!nextLoggedIn) {
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
    _controller.onLoginSuccess();
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
    if (_controller.courseChangeRules.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          minChildSize: 0.38,
          maxChildSize: 0.92,
          builder: (context, scrollController) {
            return ScheduleChangeSheet(
              changeRules: _controller.courseChangeRules,
              displayWeek: _controller.displayWeek,
              scrollController: scrollController,
            );
          },
        );
      },
    );
  }

  Widget _buildLoginBody() => AuthRequiredView(
    title: '登录后查看课表',
    message: '课表刷新依赖教务系统会话，登录后即可同步最新课程数据。',
    buttonLabel: '登录教务系统',
    onAction: () => _presentLoginPrompt(force: true),
    icon: Icons.calendar_month_outlined,
  );

  Widget _buildScheduleBody() {
    if (_controller.loading && _controller.courses.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.error != null && _controller.courses.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_controller.error!, style: TextStyle(color: cs.error)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _refreshScheduleOrLogin,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_controller.courses.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('暂无课表数据'),
            const SizedBox(height: 12),
            if (_controller.loggedIn)
              FilledButton(
                onPressed: _refreshScheduleOrLogin,
                child: const Text('刷新课表'),
              ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_controller.loading) const LinearProgressIndicator(minHeight: 2),
        if (_controller.infoMessage != null ||
            _controller.scheduleUpdatedAt != null)
          ScheduleInfoBanner(
            message: _controller.infoMessage,
            updatedAt: _controller.scheduleUpdatedAt,
            loggedIn: _controller.loggedIn,
          ),
        Expanded(child: _buildWeekPager()),
      ],
    );
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
            actualCurrentWeek: _controller.currentWeek,
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
          appBar: AppBar(
            title: const Text('课表'),
            actions: (_controller.loggedIn || _controller.courses.isNotEmpty)
                ? [
                    if (_controller.courseChangeRules.isNotEmpty)
                      IconButton(
                        tooltip: '调课提醒',
                        onPressed: _showCourseChangeSheet,
                        icon: Badge(
                          label: Text(
                            _controller.courseChangeRules.length > 99
                                ? '99+'
                                : '${_controller.courseChangeRules.length}',
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
