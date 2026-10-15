import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_service.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_subscription_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores subscription by normalized activity title', () async {
    final service = SecondClassroomSubscriptionService(
      nowProvider: () => DateTime(2026, 6, 9, 12),
      notifyRecruitingActivity: ({
        required id,
        required title,
        required body,
        required payload,
      }) async {},
    );

    final count = await service.subscribe(_activity);

    expect(count, 1);
    expect(await service.loadSubscribedIds(), {2485});
    expect(await service.loadSubscribedKeys(), {'榜样分享活动'});
  });

  test('notifies when a same-name activity starts recruiting', () async {
    final notifications = <_RecruitingNotification>[];
    var now = DateTime(2026, 6, 9, 12);
    final service = SecondClassroomSubscriptionService(
      nowProvider: () => now,
      notifyRecruitingActivity:
          ({
            required id,
            required title,
            required body,
            required payload,
          }) async {
            notifications.add(
              _RecruitingNotification(
                id: id,
                title: title,
                body: body,
                payload: payload,
              ),
            );
          },
    );

    await service.subscribe(
      _activity.copyWith(
        registrationStartAt: DateTime(2026, 6, 9, 13),
        registrationEndAt: DateTime(2026, 6, 9, 15),
      ),
    );

    now = DateTime(2026, 6, 9, 13, 30);
    final result = await service.notifyRecruitingMatchesForActivities([
      _activity,
    ]);
    final duplicateResult = await service.notifyRecruitingMatchesForActivities([
      _activity,
    ]);

    expect(result.notificationCount, 1);
    expect(duplicateResult.notificationCount, 0);
    expect(notifications, hasLength(1));
    expect(
      notifications.single.id,
      secondClassroomRecruitingNotificationId(2485),
    );
    expect(notifications.single.title, '订阅活动开始招募');
    expect(notifications.single.payload, 'second-classroom?id=2485');
  });

  test(
    'notifies for a new same-name activity but suppresses current one',
    () async {
      final notifications = <_RecruitingNotification>[];
      final service = SecondClassroomSubscriptionService(
        nowProvider: () => DateTime(2026, 6, 9, 12),
        notifyRecruitingActivity:
            ({
              required id,
              required title,
              required body,
              required payload,
            }) async {
              notifications.add(
                _RecruitingNotification(
                  id: id,
                  title: title,
                  body: body,
                  payload: payload,
                ),
              );
            },
      );

      await service.subscribe(_activity);

      final firstResult = await service.notifyRecruitingMatchesForActivities([
        _activity,
      ]);
      final newActivityResult = await service
          .notifyRecruitingMatchesForActivities([_activity.copyWith(id: 3001)]);

      expect(firstResult.notificationCount, 0);
      expect(newActivityResult.notificationCount, 1);
      expect(notifications.single.payload, 'second-classroom?id=3001');
    },
  );

  test('unsubscribe removes stored activity name', () async {
    final service = SecondClassroomSubscriptionService(
      nowProvider: () => DateTime(2026, 6, 9, 12),
      notifyRecruitingActivity: ({
        required id,
        required title,
        required body,
        required payload,
      }) async {},
    );

    await service.subscribe(_activity);
    await service.unsubscribeActivity(_activity);

    expect(await service.loadSubscribedIds(), isEmpty);
    expect(await service.loadSubscribedKeys(), isEmpty);
  });

  test(
    'automatic check throttles success but manual checks always run',
    () async {
      var now = DateTime(2026, 6, 9, 12);
      final source = _CountingActivityService();
      final service = SecondClassroomSubscriptionService(
        activityService: source,
        nowProvider: () => now,
        notifyRecruitingActivity: _ignoreNotification,
      );
      await service.subscribe(_activity);

      await service.checkRecruitingMatches(automatic: true);
      await service.checkRecruitingMatches(automatic: true);
      expect(source.calls, 1);

      await service.checkRecruitingMatches();
      expect(source.calls, 2);

      now = now.add(const Duration(minutes: 5));
      await service.checkRecruitingMatches(automatic: true);
      expect(source.calls, 3);
    },
  );

  test('automatic check singleflights and retries after failure', () async {
    final source = _CountingActivityService();
    var now = DateTime(2026, 6, 9, 12);
    final service = SecondClassroomSubscriptionService(
      activityService: source,
      nowProvider: () => now,
      notifyRecruitingActivity: _ignoreNotification,
    );
    await service.subscribe(_activity);
    final gate = Completer<void>();
    source.gate = gate;

    final first = service.checkRecruitingMatches(automatic: true);
    final second = service.checkRecruitingMatches(automatic: true);
    for (var i = 0; i < 20 && source.calls == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(source.calls, 1);
    gate.complete();
    await Future.wait([first, second]);

    now = now.add(const Duration(minutes: 5));
    source.failureCount = 1;
    await expectLater(
      service.checkRecruitingMatches(automatic: true),
      throwsStateError,
    );
    await service.checkRecruitingMatches(automatic: true);
    expect(source.calls, 3);
  });

  test(
    'subscription mutation invalidates automatic success throttle',
    () async {
      var now = DateTime(2026, 6, 9, 12);
      final source = _CountingActivityService();
      final service = SecondClassroomSubscriptionService(
        activityService: source,
        nowProvider: () => now,
        notifyRecruitingActivity: _ignoreNotification,
      );
      await service.subscribe(_activity);
      await service.checkRecruitingMatches(automatic: true);
      now = now.add(const Duration(minutes: 1));

      await service.subscribe(_activity.copyWith(title: '新活动'));
      await service.checkRecruitingMatches(automatic: true);

      expect(source.calls, 2);
    },
  );

  test('clock rollback does not suppress automatic checks', () async {
    var now = DateTime(2026, 6, 9, 12);
    final source = _CountingActivityService();
    final service = SecondClassroomSubscriptionService(
      activityService: source,
      nowProvider: () => now,
      notifyRecruitingActivity: _ignoreNotification,
    );
    await service.subscribe(_activity);
    await service.checkRecruitingMatches(automatic: true);
    now = now.subtract(const Duration(minutes: 1));
    await service.checkRecruitingMatches(automatic: true);
    expect(source.calls, 2);
  });
}

Future<void> _ignoreNotification({
  required int id,
  required String title,
  required String body,
  required String payload,
}) async {}

class _CountingActivityService extends SecondClassroomService {
  int calls = 0;
  int failureCount = 0;
  Completer<void>? gate;

  @override
  Future<SecondClassroomActivityPage> fetchAllActivities(
    SecondClassroomActivityQuery query,
  ) async {
    calls++;
    final activeGate = gate;
    if (activeGate != null) await activeGate.future;
    if (failureCount > 0) {
      failureCount--;
      throw StateError('network failed');
    }
    return const SecondClassroomActivityPage(
      items: [],
      pageIndex: 1,
      pageSize: 30,
      totalPages: 1,
      count: 0,
    );
  }
}

final _activity = SecondClassroomActivity(
  id: 2485,
  title: '榜样分享活动',
  coverId: 'cover-id',
  iconId: 'icon-id',
  registrationStartAt: DateTime(2026, 6, 9, 10),
  registrationEndAt: DateTime(2026, 6, 9, 14),
  activityStartAt: DateTime(2026, 6, 9, 16),
  activityEndAt: DateTime(2026, 6, 9, 17),
  creditHours: 0,
  location: '兴德楼北楼201',
  summary: '报名成功后加群',
  contactName: '张展健',
  contactPhone: '18536419261',
  categoryName: '思想成长',
  organizerName: '建工学院团委学生会',
  capacity: 90,
  enrolledCount: 31,
  isRegistered: false,
  hasCheckedIn: false,
  hasRetaken: false,
);

class _RecruitingNotification {
  const _RecruitingNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
  });

  final int id;
  final String title;
  final String body;
  final String payload;
}
