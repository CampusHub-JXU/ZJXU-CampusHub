import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_subscription_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores subscription by normalized activity title', () async {
    final service = SecondClassroomSubscriptionService(
      nowProvider: () => DateTime(2026, 6, 9, 12),
      notifyRecruitingActivity:
          ({
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
      notifyRecruitingActivity:
          ({
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
