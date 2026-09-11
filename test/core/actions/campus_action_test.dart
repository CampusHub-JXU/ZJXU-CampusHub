import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/actions/campus_action.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_executor.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_ids.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_registry.dart';
import 'package:jxu_campus_hub/core/actions/campus_deep_link.dart';
import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CampusActionRegistry', () {
    test('action id 唯一且 Catalog 的 primaryActionId 均可解析', () {
      final all = CampusActionRegistry.instance.all.toList();
      final ids = all.map((action) => action.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'action id 必须唯一');

      for (final entry in AppFeaturesConfig.entries) {
        expect(
          CampusActionRegistry.instance.findById(entry.primaryActionId),
          isNotNull,
          reason: '${entry.id} -> ${entry.primaryActionId} 未注册',
        );
      }
    });

    test('首批 PRD action id 均已注册', () {
      const required = <String>{
        CampusActionIds.scheduleOpen,
        CampusActionIds.scheduleToday,
        CampusActionIds.gradesOpen,
        CampusActionIds.campusCardOpen,
        CampusActionIds.campusCardPayment,
        CampusActionIds.campusCardRecharge,
        CampusActionIds.campusCardResetPassword,
        CampusActionIds.electricityOpen,
        CampusActionIds.electricityRecharge,
        CampusActionIds.libraryOpen,
        CampusActionIds.noticeInbox,
        CampusActionIds.serviceHallOpen,
        CampusActionIds.oneStopServiceOpen,
        CampusActionIds.microLifeOpen,
        CampusActionIds.shuatiOpen,
      };
      for (final id in required) {
        expect(CampusActionRegistry.instance.contains(id), isTrue, reason: id);
      }
    });
  });

  group('CampusDeepLink', () {
    test('解析新格式 action 链接', () {
      expect(
        CampusDeepLink.parse('jxucampushub://action/schedule.today'),
        CampusActionIds.scheduleToday,
      );
      expect(
        CampusDeepLink.parse('jxucampushub://action/campus-card.payment'),
        CampusActionIds.campusCardPayment,
      );
    });

    test('兼容旧 shortcut 链接', () {
      expect(
        CampusDeepLink.parse('jxucampushub://shortcut/campus-card-payment'),
        CampusActionIds.campusCardPayment,
      );
      expect(
        CampusDeepLink.parse('jxucampushub://shortcut/shuati-practice'),
        CampusActionIds.shuatiOpen,
      );
    });

    test('拒绝未注册 action、未知 host 与非法 scheme', () {
      expect(
        CampusDeepLink.parse('jxucampushub://action/unknown.action'),
        isNull,
      );
      expect(CampusDeepLink.parse('jxucampushub://shortcut/unknown'), isNull);
      expect(CampusDeepLink.parse('https://action/schedule.today'), isNull);
      expect(CampusDeepLink.parse('jxucampushub://action/'), isNull);
      expect(CampusDeepLink.parse('not a uri'), isNull);
    });
  });

  testWidgets('未注册 action 返回 unsupported 且不导航', (tester) async {
    late CampusActionResult result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await CampusActionExecutor.instance.execute(
                  context,
                  'nope.missing',
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(result.status, CampusActionStatus.unsupported);
  });
}
