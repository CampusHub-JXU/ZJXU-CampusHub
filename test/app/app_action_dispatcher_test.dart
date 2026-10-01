import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/app_action_dispatcher.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_ids.dart';

void main() {
  late Future<void> Function(String, {Object? extra}) originalPush;

  setUp(() {
    originalPush = AppActionDispatcher.pushRoute;
  });

  tearDown(() {
    AppActionDispatcher.pushRoute = originalPush;
  });

  test('route action with extra is pushed with that extra', () async {
    final calls = <(String, Object?)>[];
    AppActionDispatcher.pushRoute = (routeName, {extra}) async {
      calls.add((routeName, extra));
    };

    await AppActionDispatcher.dispatch(CampusActionIds.academicWebOpen);

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'external-webview');
    expect(calls.single.$2, {'title': '教务系统', 'academicEntry': true});
  });

  test('route action without extra is pushed with null extra', () async {
    final calls = <(String, Object?)>[];
    AppActionDispatcher.pushRoute = (routeName, {extra}) async {
      calls.add((routeName, extra));
    };

    await AppActionDispatcher.dispatch(CampusActionIds.gradesOpen);

    expect(calls.single.$1, 'grades');
    expect(calls.single.$2, isNull);
  });

  test('unknown action id is ignored', () async {
    var called = false;
    AppActionDispatcher.pushRoute = (routeName, {extra}) async {
      called = true;
    };

    await AppActionDispatcher.dispatch('no-such-action');

    expect(called, isFalse);
  });
}
