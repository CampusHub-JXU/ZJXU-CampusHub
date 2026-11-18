import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/academic/schedule_model.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/util/json_coerce.dart';
import 'second_classroom_enroll_gateway.dart';
import 'second_classroom_matcher.dart';
import 'second_classroom_model.dart';
import 'second_classroom_schedule_conflict.dart';
import 'second_classroom_service.dart';

typedef SecondClassroomRecruitingNotifier = Future<void> Function({
  required int id,
  required String title,
  required String body,
  required String payload,
});

const _subscriptionsKey = 'second_classroom_subscriptions_v2';
const _legacySubscriptionsKey = 'second_classroom_subscriptions_v1';
const _rulesKey = 'second_classroom_rule_subscriptions_v1';
const _ruleMatchesKey = 'second_classroom_rule_matches_v1';
const _recruitingNotificationBaseId = 500000;
const _automaticCheckMinInterval = Duration(minutes: 5);

class SecondClassroomRuleSubscription {
  const SecondClassroomRuleSubscription({
    required this.keywords,
    required this.createdAt,
  });
  final List<String> keywords;
  final DateTime createdAt;
  Map<String, dynamic> toJson() => {
    'keywords': keywords,
    'createdAt': createdAt.toIso8601String(),
  };
}

class SecondClassroomMonitorResult {
  const SecondClassroomMonitorResult({
    required this.subscriptionCount,
    required this.checkedActivityCount,
    required this.notificationCount,
  });

  final int subscriptionCount;
  final int checkedActivityCount;
  final int notificationCount;
}

/// 课表课程来源：由 app 组合层（main / 后台 dispatcher）绑定
/// ScheduleService 快照，feature 之间不横向依赖；未绑定视为无课表数据。
typedef SecondClassroomCourseLoader = Future<List<CourseEntry>> Function();

class SecondClassroomSubscriptionService {
  SecondClassroomSubscriptionService({
    SecondClassroomRecruitingNotifier? notifyRecruitingActivity,
    SecondClassroomService? activityService,
    DateTime Function()? nowProvider,
  }) : _notifyRecruitingActivity =
           notifyRecruitingActivity ?? _defaultNotifyRecruitingActivity,
       _activityService = activityService ?? SecondClassroomService.instance,
       _nowProvider = nowProvider ?? DateTime.now;

  static final SecondClassroomSubscriptionService instance =
      SecondClassroomSubscriptionService();

  /// 课表冲突检查的数据来源；默认空实现（无课程），组合层必须绑定真实
  /// ScheduleService 快照读取。WorkManager isolate 需要在各自入口绑定。
  static SecondClassroomCourseLoader courseLoader = () async => const [];

  final SecondClassroomRecruitingNotifier _notifyRecruitingActivity;
  final SecondClassroomService _activityService;
  final DateTime Function() _nowProvider;
  DateTime? _lastAutomaticCheckSucceededAt;
  Future<SecondClassroomMonitorResult>? _automaticCheckInFlight;
  int _subscriptionGeneration = 0;

  Future<List<SecondClassroomRuleSubscription>> loadRuleSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_rulesKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map(
            (entry) => SecondClassroomRuleSubscription(
              keywords: (entry['keywords'] as List)
                  .whereType<String>()
                  .toList(),
              createdAt: entry['createdAt'] is int
                  ? DateTime.fromMillisecondsSinceEpoch(
                      entry['createdAt'] as int,
                    )
                  : DateTime.parse(entry['createdAt'] as String),
            ),
          )
          .where((rule) => rule.keywords.isNotEmpty)
          .toList();
    } catch (_) {
      AppLogger.instance.storage(LogLevel.warn, '第二课堂规则订阅读取失败');
      return [];
    }
  }

  Future<void> addRuleSubscription(String input) async {
    final keywords = secondClassroomKeywords(input);
    if (keywords.isEmpty) return;
    final rules = await loadRuleSubscriptions();
    final key = keywords.map(normalizeSecondClassroomTag).join(' ');
    if (rules.any(
      (rule) => rule.keywords.map(normalizeSecondClassroomTag).join(' ') == key,
    )) {
      return;
    }
    rules.add(
      SecondClassroomRuleSubscription(
        keywords: keywords,
        createdAt: _nowProvider(),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _rulesKey,
      jsonEncode(
        rules
            .map(
              (rule) => {
                'keywords': rule.keywords,
                'createdAt': rule.createdAt.millisecondsSinceEpoch,
              },
            )
            .toList(),
      ),
    );
    _invalidateAutomaticCheck();
  }

  Future<void> removeRuleSubscription(
    SecondClassroomRuleSubscription rule,
  ) async {
    final rules = await loadRuleSubscriptions();
    rules.removeWhere(
      (item) =>
          item.createdAt == rule.createdAt &&
          item.keywords.join('\u0000') == rule.keywords.join('\u0000'),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _rulesKey,
      jsonEncode(
        rules
            .map(
              (item) => {
                'keywords': item.keywords,
                'createdAt': item.createdAt.millisecondsSinceEpoch,
              },
            )
            .toList(),
      ),
    );
    _invalidateAutomaticCheck();
  }

  Future<bool> isAutoEnrollEnabled() =>
      SecondClassroomEnrollGateway.instance.isAutoEnrollEnabled();
  Future<void> setAutoEnrollEnabled(bool enabled) =>
      SecondClassroomEnrollGateway.instance.setAutoEnrollEnabled(enabled);

  Future<List<SecondClassroomActivity>> loadSubscriptions() async {
    final activities = (await _loadSubscriptionRecords()).values
        .map((record) => record.activity)
        .toList();
    activities.sort(_compareActivitiesByTitle);
    return activities;
  }

  Future<Set<int>> loadSubscribedIds() async {
    return (await _loadSubscriptionRecords()).values
        .map((record) => record.activity.id)
        .where((id) => id > 0)
        .toSet();
  }

  Future<Set<String>> loadSubscribedKeys() async {
    return (await _loadSubscriptionRecords()).keys.toSet();
  }

  Future<int> subscribe(SecondClassroomActivity activity) async {
    final key = secondClassroomSubscriptionKey(activity.title);
    if (key.isEmpty) return 0;

    final records = await _loadSubscriptionRecords();
    final existing = records[key];
    final now = _nowProvider();
    final lastMatchedActivityId =
        existing?.lastMatchedActivityId ??
        (activity.isRecruitingAt(now) ? activity.id : null);
    records[key] = _SecondClassroomSubscriptionRecord(
      activity: activity,
      createdAt: existing?.createdAt ?? now,
      lastMatchedActivityId: lastMatchedActivityId,
      lastMatchedAt: existing?.lastMatchedAt,
    );
    await _saveSubscriptionRecords(records);
    _invalidateAutomaticCheck();
    return 1;
  }

  Future<void> unsubscribe(int activityId) async {
    final records = await _loadSubscriptionRecords();
    records.removeWhere((_, record) => record.activity.id == activityId);
    await _saveSubscriptionRecords(records);
    _invalidateAutomaticCheck();
  }

  Future<void> unsubscribeActivity(SecondClassroomActivity activity) async {
    final records = await _loadSubscriptionRecords();
    records.remove(secondClassroomSubscriptionKey(activity.title));
    await _saveSubscriptionRecords(records);
    _invalidateAutomaticCheck();
  }

  Future<SecondClassroomMonitorResult> checkRecruitingMatches({
    bool automatic = false,
  }) {
    if (!automatic) return _checkRecruitingMatches();

    final inFlight = _automaticCheckInFlight;
    if (inFlight != null) return inFlight;

    final now = _nowProvider();
    final lastSuccess = _lastAutomaticCheckSucceededAt;
    if (lastSuccess != null) {
      final age = now.difference(lastSuccess);
      if (!age.isNegative && age < _automaticCheckMinInterval) {
        return Future.wait([
          _loadSubscriptionRecords(),
          loadRuleSubscriptions(),
        ]).then(
          (values) => SecondClassroomMonitorResult(
            subscriptionCount:
                (values[0] as Map).length + (values[1] as List).length,
            checkedActivityCount: 0,
            notificationCount: 0,
          ),
        );
      }
    }

    final generation = _subscriptionGeneration;
    late final Future<SecondClassroomMonitorResult> request;
    request = _checkRecruitingMatches()
        .then((result) {
          if (generation == _subscriptionGeneration &&
              result.subscriptionCount > 0) {
            _lastAutomaticCheckSucceededAt = _nowProvider();
          }
          return result;
        })
        .whenComplete(() {
          if (identical(_automaticCheckInFlight, request)) {
            _automaticCheckInFlight = null;
          }
        });
    _automaticCheckInFlight = request;
    return request;
  }

  Future<SecondClassroomMonitorResult> _checkRecruitingMatches() async {
    final records = await _loadSubscriptionRecords();
    final rules = await loadRuleSubscriptions();
    if (records.isEmpty && rules.isEmpty) {
      return const SecondClassroomMonitorResult(
        subscriptionCount: 0,
        checkedActivityCount: 0,
        notificationCount: 0,
      );
    }

    final page = await _activityService.fetchAllActivities(
      const SecondClassroomActivityQuery(
        status: SecondClassroomActivityStatus.recruiting,
        sort: SecondClassroomActivitySort.latest,
        limit: 30,
      ),
    );
    return notifyRecruitingMatchesForActivities(page.items);
  }

  @visibleForTesting
  Future<SecondClassroomMonitorResult> notifyRecruitingMatchesForActivities(
    List<SecondClassroomActivity> activities,
  ) async {
    final records = await _loadSubscriptionRecords();
    final rules = await loadRuleSubscriptions();
    if (records.isEmpty && rules.isEmpty) {
      return SecondClassroomMonitorResult(
        subscriptionCount: 0,
        checkedActivityCount: activities.length,
        notificationCount: 0,
      );
    }

    final now = _nowProvider();
    final recruitingByKey = <String, SecondClassroomActivity>{};
    for (final activity in activities) {
      if (!activity.isRecruitingAt(now)) continue;
      final key = secondClassroomSubscriptionKey(activity.title);
      if (key.isEmpty) continue;

      final existing = recruitingByKey[key];
      if (existing == null ||
          _compareActivitiesByStartTime(activity, existing) < 0) {
        recruitingByKey[key] = activity;
      }
    }

    var notificationCount = 0;
    var changed = false;
    for (final entry in records.entries.toList()) {
      final match = recruitingByKey[entry.key];
      if (match == null) continue;

      final record = entry.value;
      if (record.lastMatchedActivityId == match.id) continue;

      try {
        await _notifyRecruitingActivity(
          id: secondClassroomRecruitingNotificationId(match.id),
          title: '订阅活动开始招募',
          body: '《${_compactTitle(match.title)}》正在招募，点开后可在微信中报名',
          payload: 'second-classroom?id=${match.id}',
        );
        records[entry.key] = record.copyWith(
          activity: match,
          lastMatchedActivityId: match.id,
          lastMatchedAt: now,
        );
        notificationCount += 1;
        changed = true;
      } catch (error, stackTrace) {
        AppLogger.instance.storage(
          LogLevel.warn,
          '第二课堂同名活动招募提醒发送失败: activity=${match.id}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    if (changed) {
      await _saveSubscriptionRecords(records);
    }

    notificationCount += await _notifyRuleMatches(activities, rules, now);
    return SecondClassroomMonitorResult(
      subscriptionCount: records.length + rules.length,
      checkedActivityCount: activities.length,
      notificationCount: notificationCount,
    );
  }

  Future<int> _notifyRuleMatches(
    List<SecondClassroomActivity> activities,
    List<SecondClassroomRuleSubscription> rules,
    DateTime now,
  ) async {
    if (rules.isEmpty) return 0;
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList(_ruleMatchesKey) ?? []).toSet();
    var count = 0;
    for (final activity in activities) {
      if (activity.id <= 0 || !activity.isRecruitingAt(now)) continue;
      final matched = rules
          .where(
            (rule) =>
                secondClassroomMatchesKeywords(activity.title, rule.keywords),
          )
          .toList();
      if (matched.isEmpty) continue;
      if (seen.contains('${activity.id}')) {
        if (await isAutoEnrollEnabled()) {
          await SecondClassroomEnrollGateway.instance.submit(activity);
        }
        continue;
      }
      var suffix = '';
      try {
        await SemesterCalendar.instance.init();
        final courses = await SecondClassroomSubscriptionService.courseLoader();
        final conflicts = secondClassroomScheduleConflicts(
          activityStart: activity.activityStartAt,
          activityEnd: activity.activityEndAt,
          semesterStart: SemesterCalendar.instance.semesterStartDate.value,
          courses: courses,
        );
        if (conflicts.isNotEmpty) suffix = '；课表冲突：${conflicts.join('、')}';
      } catch (_) {
        AppLogger.instance.storage(LogLevel.warn, '第二课堂课表冲突检查不可用');
      }
      var action = '点开查看详情';
      if (await isAutoEnrollEnabled()) {
        final result = await SecondClassroomEnrollGateway.instance.submit(
          activity,
        );
        action = switch (result) {
          SecondClassroomEnrollResult.done => '报名成功',
          SecondClassroomEnrollResult.needsForm => '需手动填表报名',
          SecondClassroomEnrollResult.needsLogin => '登录失效，请重新登录',
          SecondClassroomEnrollResult.failed =>
            SecondClassroomEnrollGateway.instance.lastFailureReason ??
                '报名失败，请手动查看',
          SecondClassroomEnrollResult.pending => '报名结果待核验',
          SecondClassroomEnrollResult.unavailable => '报名暂不可用，请手动查看',
        };
        if (result == SecondClassroomEnrollResult.needsLogin) {
          await AppNotificationService.instance.showAppNotification(
            id: secondClassroomRecruitingNotificationId(activity.id) + 1000000,
            title: '第二课堂登录失效',
            body: '请重新登录后继续使用活动报名',
            priority: AppNotificationPriority.high,
            channel: AppNotificationChannel.auth,
          );
        }
      }
      try {
        await _notifyRecruitingActivity(
          id: secondClassroomRecruitingNotificationId(activity.id),
          title: '订阅活动开始招募',
          body:
              '《${_compactTitle(activity.title)}》命中：${matched.expand((rule) => rule.keywords).toSet().join('、')}；$action$suffix',
          payload: 'second-classroom?id=${activity.id}',
        );
        seen.add('${activity.id}');
        await prefs.setStringList(_ruleMatchesKey, seen.toList());
        count++;
      } catch (_) {
        AppLogger.instance.storage(LogLevel.warn, '第二课堂规则通知发送失败');
      }
    }
    return count;
  }

  Future<Map<String, _SecondClassroomSubscriptionRecord>>
  _loadSubscriptionRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subscriptionsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        return _recordsFromJson(decoded);
      } catch (error, stackTrace) {
        AppLogger.instance.storage(
          LogLevel.warn,
          '第二课堂订阅缓存解析失败，已清空',
          error: error,
          stackTrace: stackTrace,
        );
        await prefs.remove(_subscriptionsKey);
        return <String, _SecondClassroomSubscriptionRecord>{};
      }
    }

    final legacyRaw = prefs.getString(_legacySubscriptionsKey);
    if (legacyRaw == null || legacyRaw.isEmpty) {
      return <String, _SecondClassroomSubscriptionRecord>{};
    }

    try {
      final records = _legacyRecordsFromJson(jsonDecode(legacyRaw));
      await _saveSubscriptionRecords(records);
      await prefs.remove(_legacySubscriptionsKey);
      return records;
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '第二课堂旧订阅缓存迁移失败，已清空',
        error: error,
        stackTrace: stackTrace,
      );
      await prefs.remove(_legacySubscriptionsKey);
      return <String, _SecondClassroomSubscriptionRecord>{};
    }
  }

  Map<String, _SecondClassroomSubscriptionRecord> _recordsFromJson(
    Object? decoded,
  ) {
    final list = decoded is List ? decoded : const [];
    final records = <String, _SecondClassroomSubscriptionRecord>{};
    for (final item in list) {
      if (item is! Map) continue;
      final record = _SecondClassroomSubscriptionRecord.fromJson(
        Map<String, dynamic>.from(item),
      );
      final key = secondClassroomSubscriptionKey(record.activity.title);
      if (key.isNotEmpty) records[key] = record;
    }
    return records;
  }

  Map<String, _SecondClassroomSubscriptionRecord> _legacyRecordsFromJson(
    Object? decoded,
  ) {
    final list = decoded is List ? decoded : const [];
    final records = <String, _SecondClassroomSubscriptionRecord>{};
    final now = _nowProvider();
    for (final item in list) {
      if (item is! Map) continue;
      final activity = SecondClassroomActivity.fromStoredJson(
        Map<String, dynamic>.from(item),
      );
      final key = secondClassroomSubscriptionKey(activity.title);
      if (key.isEmpty) continue;
      records[key] = _SecondClassroomSubscriptionRecord(
        activity: activity,
        createdAt: now,
        lastMatchedActivityId: activity.isRecruitingAt(now)
            ? activity.id
            : null,
        lastMatchedAt: activity.isRecruitingAt(now) ? now : null,
      );
    }
    return records;
  }

  Future<void> _saveSubscriptionRecords(
    Map<String, _SecondClassroomSubscriptionRecord> records,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final ordered = records.values.toList()..sort(_compareRecordsByTitle);
    await prefs.setString(
      _subscriptionsKey,
      jsonEncode(ordered.map((record) => record.toJson()).toList()),
    );
  }

  int _compareRecordsByTitle(
    _SecondClassroomSubscriptionRecord left,
    _SecondClassroomSubscriptionRecord right,
  ) {
    return _compareActivitiesByTitle(left.activity, right.activity);
  }

  int _compareActivitiesByTitle(
    SecondClassroomActivity left,
    SecondClassroomActivity right,
  ) {
    return left.title.compareTo(right.title);
  }

  int _compareActivitiesByStartTime(
    SecondClassroomActivity left,
    SecondClassroomActivity right,
  ) {
    final leftTime =
        left.registrationStartAt ??
        left.activityStartAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final rightTime =
        right.registrationStartAt ??
        right.activityStartAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return leftTime.compareTo(rightTime);
  }

  String _compactTitle(String title) {
    final trimmed = title.trim();
    if (trimmed.length <= 18) return trimmed;
    return '${trimmed.substring(0, 18)}...';
  }

  @visibleForTesting
  Future<void> debugClear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_subscriptionsKey);
    await prefs.remove(_legacySubscriptionsKey);
    _invalidateAutomaticCheck();
  }

  void _invalidateAutomaticCheck() {
    _subscriptionGeneration++;
    _lastAutomaticCheckSucceededAt = null;
    _automaticCheckInFlight = null;
  }
}

String secondClassroomSubscriptionKey(String title) {
  return title.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase();
}

int secondClassroomRecruitingNotificationId(int activityId) {
  return _recruitingNotificationBaseId + activityId;
}

Future<void> _defaultNotifyRecruitingActivity({
  required int id,
  required String title,
  required String body,
  required String payload,
}) {
  return AppNotificationService.instance
      .showSecondClassroomRecruitingNotification(
        id: id,
        title: title,
        body: body,
        payload: payload,
      );
}

class _SecondClassroomSubscriptionRecord {
  const _SecondClassroomSubscriptionRecord({
    required this.activity,
    required this.createdAt,
    this.lastMatchedActivityId,
    this.lastMatchedAt,
  });

  final SecondClassroomActivity activity;
  final DateTime createdAt;
  final int? lastMatchedActivityId;
  final DateTime? lastMatchedAt;

  _SecondClassroomSubscriptionRecord copyWith({
    SecondClassroomActivity? activity,
    DateTime? createdAt,
    int? lastMatchedActivityId,
    DateTime? lastMatchedAt,
  }) {
    return _SecondClassroomSubscriptionRecord(
      activity: activity ?? this.activity,
      createdAt: createdAt ?? this.createdAt,
      lastMatchedActivityId:
          lastMatchedActivityId ?? this.lastMatchedActivityId,
      lastMatchedAt: lastMatchedAt ?? this.lastMatchedAt,
    );
  }

  factory _SecondClassroomSubscriptionRecord.fromJson(
    Map<String, dynamic> json,
  ) {
    final activityJson = json['activity'];
    if (activityJson is! Map) {
      throw const FormatException('第二课堂订阅缺少 activity 字段');
    }
    return _SecondClassroomSubscriptionRecord(
      activity: SecondClassroomActivity.fromStoredJson(
        Map<String, dynamic>.from(activityJson),
      ),
      createdAt:
          parseSecondClassroomDate(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      lastMatchedActivityId: asNullableInt(json['lastMatchedActivityId']),
      lastMatchedAt: parseSecondClassroomDate(json['lastMatchedAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'activity': activity.toJson(),
      'createdAt': createdAt.toIso8601String(),
      'lastMatchedActivityId': lastMatchedActivityId,
      'lastMatchedAt': lastMatchedAt?.toIso8601String(),
    };
  }
}
