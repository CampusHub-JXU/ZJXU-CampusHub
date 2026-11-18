import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/actions/campus_action_executor.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/system_surface/system_settings_launcher.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_filter_chips.dart';
import '../../shared/widgets/app_list_tile.dart';
import '../../shared/widgets/app_search_field.dart';
import '../../shared/widgets/app_status_tag.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import 'second_classroom_auth.dart';
import 'second_classroom_cache_store.dart';
import 'second_classroom_model.dart';
import 'second_classroom_rules_page.dart';
import 'second_classroom_service.dart';
import 'second_classroom_subscription_service.dart';

part 'second_classroom_detail_image.dart';
part 'second_classroom_widgets.dart';

bool isSecondClassroomWeChatAuthUri(Uri uri) {
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  final isWeChatOauth =
      host == 'open.weixin.qq.com' &&
      path.contains('/connect/oauth2/authorize');
  return isWeChatOauth || _secondClassroomWeChatLoginHosts.contains(host);
}

bool isSecondClassroomAnonymousState(Object? userState) {
  if (userState is! Map) return false;

  final hasAnonymous = userState['hasAnonymous'] == true;
  final hasGuest = userState['hasGuest'] == true;
  return hasAnonymous || hasGuest;
}

const _secondClassroomWeChatLoginHosts = {
  'open.weixin.qq.com',
  'wx.tenpay.com',
};

bool isSecondClassroomAuthProviderEntryUrl(String currentUrl) {
  final uri = Uri.tryParse(currentUrl);
  if (uri == null) return false;

  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  return host == 'twdekt.zjxu.edu.cn' &&
      path == '/dekt/' &&
      uri.queryParameters.containsKey('_auth_provider_');
}

bool isSecondClassroomLandingRootUrl(String currentUrl) {
  final uri = Uri.tryParse(currentUrl);
  if (uri == null) return false;

  final host = uri.host.toLowerCase();
  final normalizedPath = uri.path.toLowerCase();
  return host == 'twdekt.zjxu.edu.cn' &&
      (normalizedPath == '/dekt/' || normalizedPath == '/dekt');
}

class SecondClassroomPage extends StatefulWidget {
  const SecondClassroomPage({
    super.key,
    this.initialActivityId,
    this.service,
    this.subscriptionService,
    this.cacheStore,
    this.authEnsurer,
  });

  static const authEntryUrl =
      'https://twdekt.zjxu.edu.cn/dekt/?_auth_provider_=cn.xht100.skylake.modules.dd.DingDingAuthProvider&dd_code=';
  static const initialUrl = 'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0';

  final int? initialActivityId;
  final SecondClassroomService? service;
  final SecondClassroomSubscriptionService? subscriptionService;
  final SecondClassroomCacheStore? cacheStore;

  /// 测试注入；生产使用 [SecondClassroomAuth.instance.ensureSession]。
  final Future<SecondClassroomAuthState> Function({bool force})? authEnsurer;

  @override
  State<SecondClassroomPage> createState() => _SecondClassroomPageState();
}

class _SecondClassroomPageState extends State<SecondClassroomPage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  SecondClassroomService get _service =>
      widget.service ?? SecondClassroomService.instance;

  SecondClassroomSubscriptionService get _subscriptionService =>
      widget.subscriptionService ?? SecondClassroomSubscriptionService.instance;

  SecondClassroomCacheStore get _cacheStore =>
      widget.cacheStore ?? SecondClassroomCacheStore.instance;

  SecondClassroomActivityQuery _query = const SecondClassroomActivityQuery();
  SecondClassroomCatalog? _catalog;
  List<SecondClassroomActivity> _activities = const [];
  Set<String> _subscribedKeys = const {};
  bool _loading = true;
  bool _refreshing = false;
  bool _showingCache = false;
  bool _refreshFailed = false;
  bool _openingInWeChat = false;
  int? _detailLoadingId;
  DateTime? _cacheUpdatedAt;
  SecondClassroomAuthState _authState = SecondClassroomAuthState.unavailable;
  bool _authChecked = false;
  String? _error;

  String get _wechatPageUrl => SecondClassroomPage.initialUrl;

  @override
  void initState() {
    super.initState();
    _searchController.text = _query.keyword;
    unawaited(_loadInitial());

    final initialActivityId = widget.initialActivityId;
    if (initialActivityId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openActivityById(initialActivityId));
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final cachedCatalog = await _cacheStore.loadCatalog();
    final cachedActivities = await _cacheStore.loadActivities(_query);
    final subscribedKeys = await _subscriptionService.loadSubscribedKeys();
    if (!mounted) return;

    if (cachedCatalog != null || cachedActivities != null) {
      final hasCachedActivities = cachedActivities != null;
      setState(() {
        _catalog = cachedCatalog;
        _subscribedKeys = subscribedKeys;
        if (cachedActivities != null) {
          _applyCachedActivities(cachedActivities);
        }
        _loading = !hasCachedActivities;
      });
      await _ensureSecondClassroomAuth();
      await _syncActivitiesFromNetwork(
        showInitialLoading: !hasCachedActivities,
      );
      return;
    }

    await _ensureSecondClassroomAuth();
    await _syncActivitiesFromNetwork(showInitialLoading: true);
  }

  Future<SecondClassroomAuthState> _ensureSecondClassroomAuth({
    bool force = false,
  }) async {
    final ensurer =
        widget.authEnsurer ?? SecondClassroomAuth.instance.ensureSession;
    final state = await ensurer(force: force);
    if (mounted) {
      setState(() {
        _authState = state;
        _authChecked = true;
      });
    }
    return state;
  }

  Future<void> _handleSecondClassroomLogin() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录第二课堂',
      description: '登录统一认证后可查看报名状态；活动报名仍在微信中完成',
    );
    if (!loggedIn || !mounted) return;
    final state = await _ensureSecondClassroomAuth(force: true);
    if (!mounted) return;
    if (state == SecondClassroomAuthState.authenticated) {
      await _reloadActivities();
    } else {
      _showSnackBar('第二课堂会话建立失败，请稍后重试');
    }
  }

  Future<void> _retrySecondClassroomAuth() async {
    final state = await _ensureSecondClassroomAuth(force: true);
    if (!mounted) return;
    if (state == SecondClassroomAuthState.authenticated) {
      await _reloadActivities();
    }
  }

  Future<void> _reloadActivities() async {
    await _syncActivitiesFromNetwork(showInitialLoading: _activities.isEmpty);
  }

  Future<void> _syncActivitiesFromNetwork({
    required bool showInitialLoading,
  }) async {
    final query = _query.copyWith(page: 1);
    if (!showInitialLoading && _refreshing) return;

    setState(() {
      _refreshing = true;
      _refreshFailed = false;
      _loading = showInitialLoading;
      _error = null;
    });

    try {
      final results = await Future.wait<Object>([
        _service.fetchCatalog(),
        _service.fetchAllActivities(query),
        _subscriptionService.loadSubscribedKeys(),
      ]);

      final catalog = results[0] as SecondClassroomCatalog;
      final page = results[1] as SecondClassroomActivityPage;
      final subscribedKeys = results[2] as Set<String>;
      await _cacheStore.saveCatalog(catalog);
      await _cacheStore.saveActivities(query, page.items);

      if (!mounted || !_isCurrentQuery(query)) return;
      setState(() {
        _catalog = catalog;
        _query = query;
        _activities = page.items;
        _subscribedKeys = subscribedKeys;
        _cacheUpdatedAt = DateTime.now();
        _showingCache = false;
      });
    } catch (error, stackTrace) {
      AppLogger.instance.ui(
        LogLevel.warn,
        '第二课堂完整活动列表同步失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      if (_activities.isEmpty) {
        setState(() => _error = error.toString());
      } else {
        setState(() => _refreshFailed = true);
        _showSnackBar('完整活动列表同步失败，已保留本地缓存');
      }
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _loading = false;
        });
      }
    }
  }

  void _applyCachedActivities(SecondClassroomActivityCacheSnapshot snapshot) {
    _activities = snapshot.activities;
    _cacheUpdatedAt = snapshot.updatedAt;
    _showingCache = true;
  }

  bool _isCurrentQuery(SecondClassroomActivityQuery query) {
    return _query.categoryId == query.categoryId &&
        _query.status == query.status &&
        _query.departmentId == query.departmentId &&
        _query.sort == query.sort &&
        _query.organizationType == query.organizationType &&
        _query.keyword == query.keyword;
  }

  Future<void> _openInWeChat(
    String url, {
    String successMessage = '已请求打开微信，若未直达请复制关键词到微信「搜一搜」搜索「青春嘉大」完成授权',
  }) async {
    if (_openingInWeChat) return;
    _openingInWeChat = true;
    AppLogger.instance.webview(LogLevel.info, '第二课堂打开微信授权页: $url');
    try {
      if (!mounted) return;
      await CampusActionExecutor.instance.executeWechat(
        context,
        url: url,
        title: '第二课堂',
        // 第二课堂服务在「青春嘉大」公众号内；拉起失败复制关键词到微信搜索。
        searchKeyword: '青春嘉大',
        successMessage: successMessage,
      );
    } finally {
      _openingInWeChat = false;
    }
  }

  Future<void> _applyQuery(SecondClassroomActivityQuery query) async {
    final nextQuery = query.copyWith(page: 1, searchUpdate: true);
    final cachedActivities = await _cacheStore.loadActivities(nextQuery);
    final subscribedKeys = await _subscriptionService.loadSubscribedKeys();
    if (!mounted) return;

    setState(() {
      _query = nextQuery;
      _subscribedKeys = subscribedKeys;
      _error = null;
      if (cachedActivities != null) {
        _applyCachedActivities(cachedActivities);
        _loading = false;
      } else {
        _activities = const [];
        _cacheUpdatedAt = null;
        _showingCache = false;
        _loading = true;
      }
    });
    await _syncActivitiesFromNetwork(
      showInitialLoading: cachedActivities == null,
    );
  }

  Future<void> _openActivityById(int activityId) async {
    await _openActivityDetail(
      SecondClassroomActivity(
        id: activityId,
        title: '活动详情',
        coverId: '',
        iconId: '',
        registrationStartAt: null,
        registrationEndAt: null,
        activityStartAt: null,
        activityEndAt: null,
        creditHours: 0,
        location: '',
        summary: '',
        contactName: '',
        contactPhone: '',
        categoryName: '',
        organizerName: '',
        capacity: 0,
        enrolledCount: 0,
        isRegistered: false,
        hasCheckedIn: false,
        hasRetaken: false,
      ),
    );
  }

  Future<void> _openActivityDetail(SecondClassroomActivity activity) async {
    if (_detailLoadingId != null) return;
    setState(() => _detailLoadingId = activity.id);
    try {
      final authState = await _ensureSecondClassroomAuth();
      if (!mounted) return;
      final detail = await _service.fetchActivityDetail(
        activity.id,
        authenticated: authState == SecondClassroomAuthState.authenticated,
      );
      if (!mounted) return;
      await _showActivityDetailSheet(detail);
    } catch (error, stackTrace) {
      AppLogger.instance.ui(
        LogLevel.warn,
        '第二课堂活动详情加载失败: ${activity.id}',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showSnackBar('活动详情加载失败，请稍后重试');
      }
    } finally {
      if (mounted) {
        setState(() => _detailLoadingId = null);
      }
    }
  }

  Future<void> _showActivityDetailSheet(
    SecondClassroomActivityDetail detail,
  ) async {
    var subscribed = _isActivitySubscribed(detail.activity);
    var busy = false;
    await AppFeedback.sheet<void>(
      context,
      scrollControlled: true,
      builder: (sheetContext) {
        return Theme(
          data: Theme.of(sheetContext)
              .copyWith(splashFactory: InkRipple.splashFactory),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              return _ActivityDetailSheet(
                detail: detail,
                imageUrl: _service.imageUrl(detail.activity.coverId),
                subscribed: subscribed,
                busy: busy,
                onOpenInWeChat: () {
                  _openInWeChat(
                    _service.activityWebUrl(detail.activity.id),
                    successMessage: '已请求打开微信，若未直达请复制关键词到微信「搜一搜」搜索「青春嘉大」查看活动详情',
                  );
                },
                onToggleSubscription: () async {
                  setSheetState(() => busy = true);
                  final nextSubscribed = await _toggleSubscription(
                    detail.activity,
                  );
                  if (sheetContext.mounted) {
                    setSheetState(() {
                      subscribed = nextSubscribed;
                      busy = false;
                    });
                  }
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<bool> _toggleSubscription(SecondClassroomActivity activity) async {
    final wasSubscribed = _isActivitySubscribed(activity);
    if (wasSubscribed) {
      await _subscriptionService.unsubscribeActivity(activity);
      if (mounted) {
        setState(() {
          _subscribedKeys = {..._subscribedKeys}
            ..remove(secondClassroomSubscriptionKey(activity.title));
        });
        _showSnackBar('已取消同名活动招募提醒');
      }
      return false;
    }

    await _subscriptionService.subscribe(activity);
    if (mounted) {
      setState(() {
        _subscribedKeys = {
          ..._subscribedKeys,
          secondClassroomSubscriptionKey(activity.title),
        };
      });
      _showSnackBar('已订阅，同名活动开始招募时将提醒');
    }
    return true;
  }

  Future<void> _openSubscriptionsSheet() async {
    final subscriptions = await _subscriptionService.loadSubscriptions();
    if (!mounted) return;

    await AppFeedback.sheet<void>(
      context,
      builder: (sheetContext) {
        var activities = subscriptions;
        return Theme(
          data: Theme.of(sheetContext)
              .copyWith(splashFactory: InkRipple.splashFactory),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              return _SubscriptionSheet(
                activities: activities,
                onOpen: (activity) {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openActivityDetail(activity));
                },
                onManageRules: () {
                  Navigator.of(sheetContext).pop();
                  _openRuleManager();
                },
                onRemove: (activity) async {
                  await _subscriptionService.unsubscribeActivity(activity);
                  if (mounted) {
                    setState(() {
                      _subscribedKeys = {
                        ..._subscribedKeys,
                      }..remove(secondClassroomSubscriptionKey(activity.title));
                    });
                  }
                  if (sheetContext.mounted) {
                    setSheetState(() {
                      final key = secondClassroomSubscriptionKey(
                        activity.title,
                      );
                      activities = activities
                          .where(
                            (item) =>
                                secondClassroomSubscriptionKey(item.title) !=
                                key,
                          )
                          .toList();
                    });
                  }
                },
              );
            },
          ),
        );
      },
    );
  }

  void _openRuleManager() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SecondClassroomRulesPage()),
    );
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    AppFeedback.toast(context, message);
  }

  Future<void> _openFilterSheet() async {
    final next = await AppFeedback.sheet<SecondClassroomActivityQuery>(
      context,
      scrollControlled: true,
      builder: (sheetContext) => _FilterSheet(query: _query, catalog: _catalog),
    );
    if (!mounted || next == null || _isSameFilter(next, _query)) return;
    await _applyQuery(next);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(splashFactory: InkRipple.splashFactory),
      child: Scaffold(
        appBar: AppAppBar(
          title: const Text('第二课堂'),
          actions: [
            // 直达只留「订阅」一个入口（含已订阅活动名与关键词规则，在弹层内
            // 分流）；低频动作收进 ⋮（design-guidelines §4.6）。
            _SubscriptionActionButton(
              count: _subscribedKeys.length,
              onPressed: _openSubscriptionsSheet,
            ),
            PopupMenuButton<_SecondClassroomAction>(
              tooltip: '更多操作',
              onSelected: (action) {
                switch (action) {
                  case _SecondClassroomAction.rules:
                    _openRuleManager();
                  case _SecondClassroomAction.wechat:
                    _openInWeChat(_wechatPageUrl);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _SecondClassroomAction.rules,
                  child: Text('关键词订阅规则'),
                ),
                PopupMenuItem(
                  value: _SecondClassroomAction.wechat,
                  child: Text('在微信中打开'),
                ),
              ],
            ),
          ],
        ),
        body: _loading
            ? const _LoadingSkeleton()
            : _error != null && _activities.isEmpty
            ? _ErrorState(message: _error!, onRetry: _loadInitial)
            : RefreshIndicator(
                onRefresh: _reloadActivities,
                child: _buildActivityList(),
              ),
      ),
    );
  }

  Widget _buildActivityList() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.md,
        AppSpacing.pageMargin,
        28,
      ),
      children: [
        AppSearchField(
          controller: _searchController,
          hintText: '搜索活动名称、地点或组织',
          onChanged: (_) {},
          onSubmitted: (keyword) {
            _applyQuery(_query.copyWith(keyword: keyword.trim()));
          },
          onClear: () {
            _searchController.clear();
            if (_query.keyword.isNotEmpty) {
              _applyQuery(_query.copyWith(keyword: ''));
            }
          },
        ),
        if (_authChecked &&
            _authState != SecondClassroomAuthState.authenticated) ...[
          const SizedBox(height: AppSpacing.md),
          _SecondClassroomAuthBanner(
            state: _authState,
            onLogin: _handleSecondClassroomLogin,
            onRetry: _retrySecondClassroomAuth,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.md),
        AppFilterChips<SecondClassroomActivityStatus>(
          padding: EdgeInsets.zero,
          options: [
            for (final status in _statusChipValues)
              AppFilterOption(
                status,
                status == SecondClassroomActivityStatus.all
                    ? '全部'
                    : status.label,
              ),
          ],
          selected: _query.status,
          onSelected: (status) {
            if (status == _query.status) return;
            _applyQuery(_query.copyWith(status: status));
          },
        ),
        const SizedBox(height: AppSpacing.xs),
        _ListToolbar(
          activityCount: _activities.length,
          sort: _query.sort,
          activeFilterCount: _activeFilterCount(_query),
          onSortChanged: (sort) {
            if (sort == _query.sort) return;
            _applyQuery(_query.copyWith(sort: sort));
          },
          onOpenFilters: _openFilterSheet,
        ),
        RefreshStatusLine(
          updatedAt: _cacheUpdatedAt,
          refreshing: _refreshing,
          failed: _refreshFailed,
          prefix: _showingCache ? '本地缓存' : null,
          loadingLabel: '正在同步活动…',
        ),
        const SizedBox(height: AppSpacing.md),
        if (_activities.isEmpty)
          const _EmptyActivityState()
        else ...[
          for (final activity in _activities) ...[
            _ActivityCard(
              activity: activity,
              imageUrl: _service.imageUrl(activity.coverId),
              subscribed: _isActivitySubscribed(activity),
              loading: _detailLoadingId == activity.id,
              onTap: () => _openActivityDetail(activity),
              onSubscribe: () => _toggleSubscription(activity),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (!_refreshing)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Text(
                  '已加载全部活动',
                  style: context.appText.meta.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  bool _isActivitySubscribed(SecondClassroomActivity activity) {
    return _subscribedKeys.contains(
      secondClassroomSubscriptionKey(activity.title),
    );
  }
}

class _SubscriptionActionButton extends StatelessWidget {
  const _SubscriptionActionButton({
    required this.count,
    required this.onPressed,
  });

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      icon: const Icon(Icons.notifications_outlined),
      tooltip: '订阅管理',
      onPressed: onPressed,
    );
    if (count == 0) return button;
    return Badge.count(count: count, child: button);
  }
}

/// AppBar ⋮ 菜单里的动作。
enum _SecondClassroomAction { rules, wechat }

/// 状态 chip 行里平铺的状态；「全部活动（含未开放）」收进筛选弹层。
const _statusChipValues = [
  SecondClassroomActivityStatus.all,
  SecondClassroomActivityStatus.recruiting,
  SecondClassroomActivityStatus.warming,
  SecondClassroomActivityStatus.running,
  SecondClassroomActivityStatus.ended,
];

/// 弹层里生效中的筛选数：组织类型、分类、学院、含未开放活动。
int _activeFilterCount(SecondClassroomActivityQuery query) {
  var count = 0;
  if (query.organizationType != SecondClassroomOrganizationType.all) count++;
  if (query.categoryId.isNotEmpty) count++;
  if (query.departmentId.isNotEmpty) count++;
  if (query.status == SecondClassroomActivityStatus.allIncludingUnauthorized) {
    count++;
  }
  return count;
}

bool _isSameFilter(
  SecondClassroomActivityQuery a,
  SecondClassroomActivityQuery b,
) {
  return a.organizationType == b.organizationType &&
      a.categoryId == b.categoryId &&
      a.departmentId == b.departmentId &&
      a.status == b.status;
}

/// 列表上方一行：左侧计数，右侧排序菜单与「筛选」入口（§4.5）。
class _ListToolbar extends StatelessWidget {
  const _ListToolbar({
    required this.activityCount,
    required this.sort,
    required this.activeFilterCount,
    required this.onSortChanged,
    required this.onOpenFilters,
  });

  final int activityCount;
  final SecondClassroomActivitySort sort;
  final int activeFilterCount;
  final ValueChanged<SecondClassroomActivitySort> onSortChanged;
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final filtering = activeFilterCount > 0;
    return Row(
      children: [
        Expanded(child: Text('共 $activityCount 个活动', style: text.secondary)),
        PopupMenuButton<SecondClassroomActivitySort>(
          tooltip: '排序',
          initialValue: sort,
          onSelected: onSortChanged,
          itemBuilder: (context) => [
            for (final value in SecondClassroomActivitySort.values)
              PopupMenuItem(value: value, child: Text(value.label)),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sort.label,
                  style: text.secondary.copyWith(color: cs.onSurface),
                ),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        TextButton(
          onPressed: onOpenFilters,
          style: TextButton.styleFrom(
            foregroundColor: filtering ? cs.primary : cs.onSurface,
            textStyle: text.secondary.copyWith(fontWeight: FontWeight.w600),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(filtering ? '筛选 · $activeFilterCount' : '筛选'),
        ),
      ],
    );
  }
}

/// 「筛选」弹层：组织类型 / 活动分类 / 所属学院用换行 chip，最下方一个
/// 「全部活动（含未开放）」开关；「完成」时把草稿查询带回页面。
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.query, required this.catalog});

  final SecondClassroomActivityQuery query;
  final SecondClassroomCatalog? catalog;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late SecondClassroomActivityQuery _draft = widget.query;

  /// 关掉「含未开放」开关时回到的状态：打开前若本就是含未开放，则回到「全部」。
  late final SecondClassroomActivityStatus _chipStatus =
      widget.query.status ==
          SecondClassroomActivityStatus.allIncludingUnauthorized
      ? SecondClassroomActivityStatus.all
      : widget.query.status;

  void _reset() {
    setState(() {
      _draft = _draft.copyWith(
        organizationType: SecondClassroomOrganizationType.all,
        categoryId: '',
        departmentId: '',
        status: _chipStatus,
      );
    });
  }

  List<AppFilterOption<String>> _options(
    List<SecondClassroomFilterOption> options,
  ) {
    return [
      const AppFilterOption('', '全部'),
      for (final option in options) AppFilterOption(option.value, option.text),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final includeAll =
        _draft.status == SecondClassroomActivityStatus.allIncludingUnauthorized;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.listGutter,
                0,
                AppSpacing.listGutter,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PlainSectionHeader('组织类型'),
                  AppFilterChips<SecondClassroomOrganizationType>(
                    wrap: true,
                    padding: EdgeInsets.zero,
                    options: [
                      for (final value
                          in SecondClassroomOrganizationType.values)
                        AppFilterOption(
                          value,
                          value == SecondClassroomOrganizationType.all
                              ? '全部'
                              : value.label,
                        ),
                    ],
                    selected: _draft.organizationType,
                    onSelected: (value) => setState(() {
                      _draft = _draft.copyWith(organizationType: value);
                    }),
                  ),
                  if (catalog != null && catalog.categories.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.listGroupGap),
                    const PlainSectionHeader('活动分类'),
                    AppFilterChips<String>(
                      wrap: true,
                      padding: EdgeInsets.zero,
                      options: _options(catalog.categories),
                      selected: _draft.categoryId,
                      onSelected: (value) => setState(() {
                        _draft = _draft.copyWith(categoryId: value);
                      }),
                    ),
                  ],
                  if (catalog != null && catalog.departments.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.listGroupGap),
                    const PlainSectionHeader('所属学院'),
                    AppFilterChips<String>(
                      wrap: true,
                      padding: EdgeInsets.zero,
                      options: _options(catalog.departments),
                      selected: _draft.departmentId,
                      onSelected: (value) => setState(() {
                        _draft = _draft.copyWith(departmentId: value);
                      }),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.listGroupGap),
                  PlainListGroup(
                    children: [
                      PlainSwitchRow(
                        title: '全部活动（含未开放）',
                        value: includeAll,
                        onChanged: (value) => setState(() {
                          _draft = _draft.copyWith(
                            status: value
                                ? SecondClassroomActivityStatus
                                      .allIncludingUnauthorized
                                : _chipStatus,
                          );
                        }),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.listGutter,
              AppSpacing.sm,
              AppSpacing.listGutter,
              AppSpacing.lg,
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _reset,
                    child: const Text('重置'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_draft),
                    child: const Text('完成'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
