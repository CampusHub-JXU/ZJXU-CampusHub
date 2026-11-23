import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_state_view_transition.dart';

/// 新手欢迎向导的「已完成」持久化标记。
///
/// 首启一次、跳过或翻完即置 true；不并入 `AppPreferencesStore`（它只承载
/// 主题偏好，见 onboarding 任务决策）。测试环境经
/// `SharedPreferences.setMockInitialValues({})` 统一复位。
const String welcomeCompletedPrefsKey = 'welcome_completed';

/// 欢迎向导内动作落点：拿到当前全屏路由所在的导航栈，由调用方决定去向
/// （首启与「设置 → 重放」共用同一组目标，见 `app.dart` 默认注入）。
typedef WelcomeAction = void Function(NavigatorState navigator);

/// 全屏欢迎路由：不走 `showDialog`（设计棘轮只减不增），用普通 push 弹全屏
/// 页面，页面转场由全局 `pageTransitionsTheme` 统一接管。
class WelcomeFlow {
  WelcomeFlow._();

  /// 当前在途 / 已完成的欢迎路由；用于去重并让调用方能 await 关闭。
  static Future<void>? _activeFlow;

  /// 当前是否有欢迎路由在屏上（含正在关闭的）。
  static bool get isShowing => _activeFlow != null;

  /// 首次启动是否应当展示（未持久化完成标记即视为新用户）。
  static Future<bool> shouldShow() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(welcomeCompletedPrefsKey) != true;
  }

  /// 写入完成标记；跳过、翻完与系统返回都算「完成」。
  static Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(welcomeCompletedPrefsKey, true);
  }

  /// 打开欢迎页；已在屏上时直接复用在途 Future，不重复 push。
  ///
  /// 「设置 → 重放新手引导」已改走注册路由 `welcome`（routes.dart 组合层
  /// 持有 WelcomePage 与动作落点），本入口保留给需要当前导航栈的调用方；
  /// 首启见 [showOnNavigator]，直接把根导航传进来，避免依赖 overlay 内建
  /// 上下文。[onLoginShortcut] / [onNotificationsShortcut] /
  /// [onCalendarShortcut] / [onAiShortcut] 是各页主动作的落点。
  /// 不传则该页主动作按钮不显示。
  static Future<void> show(
    BuildContext context, {
    WelcomeAction? onLoginShortcut,
    WelcomeAction? onNotificationsShortcut,
    WelcomeAction? onCalendarShortcut,
    WelcomeAction? onAiShortcut,
  }) {
    return showOnNavigator(
      Navigator.of(context),
      onLoginShortcut: onLoginShortcut,
      onNotificationsShortcut: onNotificationsShortcut,
      onCalendarShortcut: onCalendarShortcut,
      onAiShortcut: onAiShortcut,
    );
  }

  /// 在指定导航栈上打开欢迎页（首启传根导航，可盖在 shell 与 dock 之上）。
  static Future<void> showOnNavigator(
    NavigatorState navigator, {
    WelcomeAction? onLoginShortcut,
    WelcomeAction? onNotificationsShortcut,
    WelcomeAction? onCalendarShortcut,
    WelcomeAction? onAiShortcut,
  }) {
    final existing = _activeFlow;
    if (existing != null) return existing;

    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => WelcomePage(
        onLoginShortcut: onLoginShortcut,
        onNotificationsShortcut: onNotificationsShortcut,
        onCalendarShortcut: onCalendarShortcut,
        onAiShortcut: onAiShortcut,
      ),
    );
    final flow = navigator
        .push(route)
        .then((_) => unawaited(markCompleted()))
        .whenComplete(() => _activeFlow = null);
    _activeFlow = flow;
    return flow;
  }

  /// 测试辅助：清掉在途引用（路由由测试自身 teardown 弹掉）。
  static void debugReset() {
    _activeFlow = null;
  }
}

/// 一页引导内容的描述。
class _WelcomeSlide {
  const _WelcomeSlide({
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
    this.actionLabel,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color accent;

  /// 本页主动作按钮文案；null 表示纯说明页（末页）。
  final String? actionLabel;

  /// 主动作落点；null 时按钮不显示。执行后向导自行关闭，由调用方导航。
  final WelcomeAction? action;
}

/// 新手欢迎向导：5 页横滑 + 页码指示器 + 跳过/下一步/动作/开始。
///
/// 主线是「登录 → 通知 → 日历同步 → AI 配置」四步设置 + 完成页；每个动作页给一个
/// 主动作（先关向导再去目标页），也可「下一步」先浏览完再自行前往。
///
/// 视觉遵循内容层排版：无框、左中轴居中、字号与字重定层级；装饰只留给
/// 顶部品牌行的微弱径向光晕，不进入正文层。
class WelcomePage extends StatefulWidget {
  const WelcomePage({
    super.key,
    this.onLoginShortcut,
    this.onNotificationsShortcut,
    this.onCalendarShortcut,
    this.onAiShortcut,
  });

  /// 第 1 页「去登录」动作：执行后关闭向导，由调用方导航到「我的」页。
  final WelcomeAction? onLoginShortcut;

  /// 第 2 页「去开启」动作：通常导航到「桌面与后台」设置页（通知/闹钟/电池）。
  final WelcomeAction? onNotificationsShortcut;

  /// 第 3 页「去设置」动作：通常导航到设置页「课表与后台」分区（日历同步开关）。
  final WelcomeAction? onCalendarShortcut;

  /// 第 4 页「去配置」动作：导航到「AI 模型与接口」设置页。
  final WelcomeAction? onAiShortcut;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  late final PageController _pageController;
  int _page = 0;

  List<_WelcomeSlide> _slides = const [];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cs = Theme.of(context).colorScheme;
    _slides = [
      _WelcomeSlide(
        icon: Icons.badge_outlined,
        title: '连接校园身份',
        body: '课表、成绩、考试要登录教务系统；\n一卡通、宿舍电费要登录统一认证。\n在「我的」页一次登录两个账号。',
        accent: cs.primary,
        actionLabel: '去登录',
        action: widget.onLoginShortcut,
      ),
      _WelcomeSlide(
        icon: Icons.notifications_outlined,
        title: '打开通知提醒',
        body: '课前提醒、公告与后台刷新都靠通知。\n权限是系统给的，现在就去开。',
        accent: cs.secondary,
        actionLabel: '去开启',
        action: widget.onNotificationsShortcut,
      ),
      _WelcomeSlide(
        icon: Icons.calendar_month_outlined,
        title: '同步课程到日历',
        body: '把课表写进系统日历，课前自动提醒。\n需先登录教务系统，在设置里开启。',
        accent: cs.tertiary,
        actionLabel: '去设置',
        action: widget.onCalendarShortcut,
      ),
      _WelcomeSlide(
        icon: Icons.auto_awesome_outlined,
        title: '配置 AI 助手',
        body: '填好 API 密钥后，刷题可用 AI 解析和追问。\n未配置也能导出学业数据给外部 AI。',
        accent: cs.tertiary,
        actionLabel: '去配置',
        action: widget.onAiShortcut,
      ),
      _WelcomeSlide(
        icon: Icons.check_circle_outline,
        title: '准备好了',
        body: '首页会列出今天的课、余额和电量。\n这份引导可随时在「设置」里重放。',
        accent: cs.primary,
      ),
    ];
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool get _isLastPage => _page == _slides.length - 1;

  Future<bool> _finish() => Navigator.of(context).maybePop();

  void _next() {
    if (_isLastPage) {
      _finish();
      return;
    }
    _pageController.nextPage(
      duration: AppMotion.page,
      curve: AppMotion.emphasized,
    );
  }

  /// 主动作：先关闭向导，再在原导航栈上打开目标页。
  Future<void> _runAction(WelcomeAction action) async {
    final navigator = Navigator.of(context);
    await _finish();
    if (!navigator.mounted) return;
    action(navigator);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final media = MediaQuery.of(context);
    final slide = _slides.isEmpty ? null : _slides[_page];
    final action = slide?.action;

    // 刻意不用 Scaffold：根 ScaffoldMessenger 会向「每一个」Scaffold 派发
    // SnackBar，全屏页若自持 Scaffold 会把启动代理提示复制一份进来。
    return Material(
      color: cs.surface,
      child: Stack(
        children: [
          // 微弱径向光晕：外壳层的氛围装饰，只落在底色上。
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.6, -0.7),
                  radius: 0.9,
                  colors: [
                    cs.primary.withValues(alpha: 0.10),
                    cs.surface.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.listGutter,
              ),
              child: Column(
                children: [
                  // 顶行：左侧产品署名，右侧跳过。
                  SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        Text('CampusHub', style: text.label),
                        const Spacer(),
                        _isLastPage
                            ? const SizedBox(width: 48)
                            : TextButton(
                                onPressed: _finish,
                                child: const Text('跳过'),
                              ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: _slides.length,
                      onPageChanged: (index) => setState(() => _page = index),
                      itemBuilder: (context, index) {
                        final slide = _slides[index];
                        // 一次性入场（淡入 + 微上浮），换页不重播。
                        return AppStateViewTransition(
                          child: _SlideBody(slide: slide),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _Dots(count: _slides.length, current: _page),
                  const SizedBox(height: AppSpacing.lg),
                  if (_isLastPage)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _finish,
                        child: const Text('开始使用'),
                      ),
                    )
                  else if (action != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => _runAction(action),
                        child: Text(slide!.actionLabel!),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: _next,
                        child: const Text('下一步'),
                      ),
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _next,
                        child: const Text('下一步'),
                      ),
                    ),
                  SizedBox(height: media.padding.bottom + AppSpacing.sm),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单页内容：图标徽标 + 大标题 + 说明，居中布局。
class _SlideBody extends StatelessWidget {
  const _SlideBody({required this.slide});

  final _WelcomeSlide slide;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AppIconBadge(
          icon: slide.icon,
          accentColor: slide.accent,
          size: AppIconBadgeSize.large,
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(slide.title, textAlign: TextAlign.center, style: text.title),
        const SizedBox(height: AppSpacing.md),
        Text(
          slide.body,
          textAlign: TextAlign.center,
          style: text.body.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 页码指示器：圆点集合，当前页拉长成短胶囊。
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final active = index == current;
        return AnimatedContainer(
          duration: AppMotion.switchFade,
          curve: AppMotion.standard,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 18 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? cs.primary : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}
