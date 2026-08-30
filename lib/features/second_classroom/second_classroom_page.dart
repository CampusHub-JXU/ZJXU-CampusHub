import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/logging/app_logger.dart';
import '../../core/wechat/wechat_launcher.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import 'second_classroom_cache_store.dart';
import 'second_classroom_model.dart';
import 'second_classroom_service.dart';
import 'second_classroom_subscription_service.dart';
import '../../shared/widgets/app_app_bar.dart';

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
  });

  static const authEntryUrl =
      'https://twdekt.zjxu.edu.cn/dekt/?_auth_provider_=cn.xht100.skylake.modules.dd.DingDingAuthProvider&dd_code=';
  static const initialUrl = 'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0';

  final int? initialActivityId;
  final SecondClassroomService? service;
  final SecondClassroomSubscriptionService? subscriptionService;

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

  final _cacheStore = SecondClassroomCacheStore.instance;

  SecondClassroomActivityQuery _query = const SecondClassroomActivityQuery();
  SecondClassroomCatalog? _catalog;
  List<SecondClassroomActivity> _activities = const [];
  Set<String> _subscribedKeys = const {};
  bool _loading = true;
  bool _refreshing = false;
  bool _showingCache = false;
  bool _openingInWeChat = false;
  int? _detailLoadingId;
  DateTime? _cacheUpdatedAt;
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
      await _syncActivitiesFromNetwork(
        showInitialLoading: !hasCachedActivities,
      );
      return;
    }

    await _syncActivitiesFromNetwork(showInitialLoading: true);
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
    String successMessage = '已打开微信，请在微信中完成第二课堂授权',
  }) async {
    if (_openingInWeChat) return;
    _openingInWeChat = true;
    AppLogger.instance.webview(LogLevel.info, '第二课堂打开微信授权页: $url');
    try {
      final opened = await WechatLauncher.instance.openUrl(url);
      if (!mounted) return;

      _showSnackBar(opened ? successMessage : '未能打开微信，请确认已安装微信后重试');
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
      final detail = await _service.fetchActivityDetail(activity.id);
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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
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
                    successMessage: '已打开微信，可直接查看该活动详情',
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

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
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

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(splashFactory: InkRipple.splashFactory),
      child: Scaffold(
        appBar: AppAppBar(
          title: const Text('第二课堂'),
          actions: [
            IconButton(
              icon: const Icon(Icons.notifications_outlined),
              tooltip: '已订阅活动名',
              onPressed: _openSubscriptionsSheet,
            ),
            IconButton(
              icon: const Icon(Icons.open_in_new_rounded),
              tooltip: '在微信中打开',
              onPressed: () {
                _openInWeChat(_wechatPageUrl);
              },
            ),
          ],
        ),
        body: _loading
            ? const _LoadingState()
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
    return ListView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        _SearchAndFilters(
          controller: _searchController,
          query: _query,
          catalog: _catalog,
          refreshing: _refreshing,
          onSearch: (keyword) {
            _applyQuery(_query.copyWith(keyword: keyword.trim()));
          },
          onClearSearch: () {
            _searchController.clear();
            _applyQuery(_query.copyWith(keyword: ''));
          },
          onQueryChanged: _applyQuery,
        ),
        const SizedBox(height: 12),
        _SubscriptionSummary(
          count: _subscribedKeys.length,
          onTap: _openSubscriptionsSheet,
        ),
        const SizedBox(height: 8),
        _SyncStatusLine(
          activityCount: _activities.length,
          updatedAt: _cacheUpdatedAt,
          showingCache: _showingCache,
          syncing: _refreshing,
        ),
        const SizedBox(height: 14),
        if (_activities.isEmpty)
          const _EmptyActivityState()
        else
          for (final activity in _activities) ...[
            _ActivityCard(
              activity: activity,
              imageUrl: _service.imageUrl(activity.coverId),
              subscribed: _isActivitySubscribed(activity),
              loading: _detailLoadingId == activity.id,
              onTap: () => _openActivityDetail(activity),
              onSubscribe: () => _toggleSubscription(activity),
            ),
            const SizedBox(height: 10),
          ],
        if (_refreshing && _activities.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_activities.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: Text('已加载全部活动')),
          ),
      ],
    );
  }

  bool _isActivitySubscribed(SecondClassroomActivity activity) {
    return _subscribedKeys.contains(
      secondClassroomSubscriptionKey(activity.title),
    );
  }
}

class _SearchAndFilters extends StatelessWidget {
  const _SearchAndFilters({
    required this.controller,
    required this.query,
    required this.catalog,
    required this.refreshing,
    required this.onSearch,
    required this.onClearSearch,
    required this.onQueryChanged,
  });

  final TextEditingController controller;
  final SecondClassroomActivityQuery query;
  final SecondClassroomCatalog? catalog;
  final bool refreshing;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearSearch;
  final ValueChanged<SecondClassroomActivityQuery> onQueryChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: onSearch,
          decoration: InputDecoration(
            hintText: '搜索活动名称、地点或组织',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: query.keyword.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '清除搜索',
                    onPressed: onClearSearch,
                  ),
            filled: true,
            fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _EnumFilterMenu<SecondClassroomActivityStatus>(
                icon: Icons.flag_outlined,
                value: query.status,
                values: SecondClassroomActivityStatus.values,
                labelFor: (value) => value.label,
                onSelected: (status) {
                  onQueryChanged(query.copyWith(status: status));
                },
              ),
              const SizedBox(width: 8),
              _EnumFilterMenu<SecondClassroomActivitySort>(
                icon: Icons.sort_rounded,
                value: query.sort,
                values: SecondClassroomActivitySort.values,
                labelFor: (value) => value.label,
                onSelected: (sort) {
                  onQueryChanged(query.copyWith(sort: sort));
                },
              ),
              const SizedBox(width: 8),
              _OptionFilterMenu(
                icon: Icons.category_outlined,
                value: query.categoryId,
                allLabel: '全部分类',
                options: catalog?.categories ?? const [],
                onSelected: (value) {
                  onQueryChanged(query.copyWith(categoryId: value));
                },
              ),
              const SizedBox(width: 8),
              _EnumFilterMenu<SecondClassroomOrganizationType>(
                icon: Icons.groups_outlined,
                value: query.organizationType,
                values: SecondClassroomOrganizationType.values,
                labelFor: (value) => value.label,
                onSelected: (organizationType) {
                  onQueryChanged(
                    query.copyWith(organizationType: organizationType),
                  );
                },
              ),
              const SizedBox(width: 8),
              _OptionFilterMenu(
                icon: Icons.apartment_outlined,
                allLabel: '全部学院',
                value: query.departmentId,
                options: catalog?.departments ?? const [],
                onSelected: (value) {
                  onQueryChanged(query.copyWith(departmentId: value));
                },
              ),
              if (refreshing) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _EnumFilterMenu<T> extends StatelessWidget {
  const _EnumFilterMenu({
    required this.icon,
    required this.value,
    required this.values,
    required this.labelFor,
    required this.onSelected,
  });

  final IconData icon;
  final T value;
  final List<T> values;
  final String Function(T value) labelFor;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return AppDropdown<T>(
      value: value,
      prefixIcon: icon,
      items: values
          .map((item) => AppDropdownItem<T>(value: item, label: labelFor(item)))
          .toList(),
      onChanged: (selected) {
        if (selected == null) return;
        onSelected(selected);
      },
    );
  }
}

class _OptionFilterMenu extends StatelessWidget {
  const _OptionFilterMenu({
    required this.icon,
    required this.allLabel,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final IconData icon;
  final String allLabel;
  final String value;
  final List<SecondClassroomFilterOption> options;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return AppDropdown<String>(
      value: value.isEmpty ? null : value,
      hint: allLabel,
      prefixIcon: icon,
      items: [
        AppDropdownItem<String>(value: '', label: allLabel),
        ...options.map(
          (option) =>
              AppDropdownItem<String>(value: option.value, label: option.text),
        ),
      ],
      onChanged: (selected) {
        onSelected(selected ?? '');
      },
    );
  }
}

class _SubscriptionSummary extends StatelessWidget {
  const _SubscriptionSummary({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.36),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.notifications_active_outlined, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  count == 0 ? '还没有订阅活动名' : '已订阅 $count 个活动名',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.activity,
    required this.imageUrl,
    required this.subscribed,
    required this.loading,
    required this.onTap,
    required this.onSubscribe,
  });

  final SecondClassroomActivity activity;
  final String imageUrl;
  final bool subscribed;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ActivityCover(imageUrl: imageUrl, size: 88),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            activity.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (loading)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          IconButton(
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              subscribed
                                  ? Icons.notifications_active_rounded
                                  : Icons.notifications_none_rounded,
                            ),
                            tooltip: subscribed ? '取消开招提醒' : '订阅开招提醒',
                            color: subscribed
                                ? cs.primary
                                : cs.onSurfaceVariant,
                            onPressed: onSubscribe,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _TinyBadge(
                          label: activity.recruitmentLabel,
                          color: _statusColor(context, activity),
                        ),
                        if (activity.categoryName.isNotEmpty)
                          _TinyBadge(label: activity.categoryName),
                        if (activity.creditHours > 0)
                          _TinyBadge(
                            label:
                                '${_formatCreditHours(activity.creditHours)} 学时',
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _MetaLine(
                      icon: Icons.event_available_outlined,
                      text:
                          '报名 ${_formatRange(activity.registrationStartAt, activity.registrationEndAt)}',
                    ),
                    const SizedBox(height: 4),
                    _MetaLine(
                      icon: Icons.schedule_outlined,
                      text:
                          '活动 ${_formatRange(activity.activityStartAt, activity.activityEndAt)}',
                    ),
                    const SizedBox(height: 4),
                    _MetaLine(
                      icon: Icons.place_outlined,
                      text: activity.location.isEmpty
                          ? '地点待确认'
                          : activity.location,
                    ),
                    const SizedBox(height: 4),
                    _MetaLine(
                      icon: Icons.people_outline_rounded,
                      text: activity.capacity > 0
                          ? '${activity.enrolledCount}/${activity.capacity} 人'
                          : '${activity.enrolledCount} 人已报名',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(BuildContext context, SecondClassroomActivity activity) {
    final cs = Theme.of(context).colorScheme;
    return switch (activity.recruitmentLabel) {
      '招募中' => const Color(0xFF168A52),
      '活动预热' => cs.primary,
      '已招满' => const Color(0xFFE08A00),
      _ => cs.onSurfaceVariant,
    };
  }
}

class _ActivityCover extends StatelessWidget {
  const _ActivityCover({required this.imageUrl, required this.size});

  final String imageUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: size,
        height: size,
        color: cs.surfaceContainerHighest,
        child: imageUrl.isEmpty
            ? Icon(Icons.workspace_premium_outlined, color: cs.primary)
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Icon(
                    Icons.workspace_premium_outlined,
                    color: cs.primary,
                  );
                },
              ),
      ),
    );
  }
}
