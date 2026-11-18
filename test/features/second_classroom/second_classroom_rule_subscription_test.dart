import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_subscription_service.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  Future<SecondClassroomSubscriptionService> buildService(
    List<_SentNotification> sent,
  ) async {
    return SecondClassroomSubscriptionService(
      nowProvider: () => DateTime(2026, 6, 9, 12),
      notifyRecruitingActivity:
          ({
            required id,
            required title,
            required body,
            required payload,
          }) async {
            sent.add(
              _SentNotification(
                id: id,
                title: title,
                body: body,
                payload: payload,
              ),
            );
          },
    );
  }

  group('addRuleSubscription', () {
    test('stores normalized keywords and ignores empty input', () async {
      final service = await buildService([]);

      await service.addRuleSubscription('   ');
      expect(await service.loadRuleSubscriptions(), isEmpty);

      await service.addRuleSubscription('经院 开跑');
      final rules = await service.loadRuleSubscriptions();

      expect(rules, hasLength(1));
      expect(rules.single.keywords, ['经院', '开跑']);
      expect(rules.single.createdAt, DateTime(2026, 6, 9, 12));
    });

    test(
      'deduplicates the same keyword set regardless of spacing/case',
      () async {
        final service = await buildService([]);

        await service.addRuleSubscription('经院 开跑');
        await service.addRuleSubscription(' 经院   开跑 ');
        await service.addRuleSubscription('经院 开跑');

        expect(await service.loadRuleSubscriptions(), hasLength(1));
      },
    );

    test('removeRuleSubscription deletes only the given rule', () async {
      final service = await buildService([]);
      await service.addRuleSubscription('经院 开跑');
      await service.addRuleSubscription('数信 编程');
      final rules = await service.loadRuleSubscriptions();

      await service.removeRuleSubscription(rules.first);

      final remaining = await service.loadRuleSubscriptions();
      expect(remaining, hasLength(1));
      expect(remaining.single.keywords, ['数信', '编程']);
    });
  });

  group('notifyRecruitingMatchesForActivities', () {
    test(
      'notifies activities that match a rule through the college alias',
      () async {
        final sent = <_SentNotification>[];
        final service = await buildService(sent);
        await service.addRuleSubscription('经院 开跑');

        final result = await service.notifyRecruitingMatchesForActivities([
          _activity(id: 3001, title: '经济学院学子 开跑啦'),
        ]);

        expect(result.subscriptionCount, 1);
        expect(result.checkedActivityCount, 1);
        expect(result.notificationCount, 1);
        expect(sent.single.payload, 'second-classroom?id=3001');
        expect(sent.single.body, contains('命中：经院、开跑'));
        expect(sent.single.body, contains('点开查看详情'));
      },
    );

    test('ignores activities that do not match the rule', () async {
      final sent = <_SentNotification>[];
      final service = await buildService(sent);
      await service.addRuleSubscription('经院');

      final result = await service.notifyRecruitingMatchesForActivities([
        _activity(id: 3002, title: '商学院学子 素拓'),
      ]);

      expect(result.notificationCount, 0);
      expect(sent, isEmpty);
    });

    test('does not notify the same activity twice', () async {
      final sent = <_SentNotification>[];
      final service = await buildService(sent);
      await service.addRuleSubscription('开跑');
      final matching = _activity(id: 3003, title: '经院学子 开跑啦');

      final first = await service.notifyRecruitingMatchesForActivities([
        matching,
      ]);
      final second = await service.notifyRecruitingMatchesForActivities([
        matching,
      ]);

      expect(first.notificationCount, 1);
      expect(second.notificationCount, 0);
      expect(sent, hasLength(1));
    });

    test('skips activities that are not recruiting yet', () async {
      final sent = <_SentNotification>[];
      final service = await buildService(sent);
      await service.addRuleSubscription('开跑');

      final result = await service.notifyRecruitingMatchesForActivities([
        _activity(
          id: 3004,
          title: '经院学子 开跑啦',
          registrationStartAt: DateTime(2026, 6, 10, 8),
        ),
      ]);

      expect(result.notificationCount, 0);
      expect(sent, isEmpty);
    });
  });
}

class _SentNotification {
  const _SentNotification({
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

SecondClassroomActivity _activity({
  required int id,
  required String title,
  DateTime? registrationStartAt,
}) {
  return SecondClassroomActivity(
    id: id,
    title: title,
    coverId: 'cover-id',
    iconId: 'icon-id',
    registrationStartAt: registrationStartAt ?? DateTime(2026, 6, 9, 10),
    registrationEndAt: DateTime(2026, 6, 9, 14),
    activityStartAt: DateTime(2026, 6, 9, 16),
    activityEndAt: DateTime(2026, 6, 9, 17),
    creditHours: 0,
    location: '兴德楼北楼201',
    summary: '',
    contactName: '',
    contactPhone: '',
    categoryName: '思想成长',
    organizerName: '经济学院团委',
    capacity: 90,
    enrolledCount: 10,
    isRegistered: false,
    hasCheckedIn: false,
    hasRetaken: false,
  );
}
