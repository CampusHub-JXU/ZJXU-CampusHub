import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/campus_refresh_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bootstrap readiness and foreground gate refresh; resume catches up',
    () async {
      var ready = false;
      var calls = 0;
      final coordinator = CampusRefreshCoordinator(
        ready: () => ready,
        refresh: () async {
          calls++;
        },
      );
      addTearDown(coordinator.dispose);
      await coordinator.refreshNow();
      expect(calls, 0);
      ready = true;
      await coordinator.refreshNow();
      expect(calls, 1);
      coordinator.setForeground(false);
      await coordinator.refreshNow();
      expect(calls, 1);
      coordinator.setForeground(true);
      await coordinator.refreshNow();
      expect(calls, 2);
    },
  );

  test(
    'concurrent triggers join; a login completion queues one follow-up',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final coordinator = CampusRefreshCoordinator(
        ready: () => true,
        refresh: () async {
          calls++;
          if (calls == 1) await gate.future;
        },
      );
      addTearDown(coordinator.dispose);
      final first = coordinator.refreshNow();
      final joined = coordinator.refreshNow();
      coordinator.requestRefresh();
      coordinator.requestRefresh();
      expect(calls, 1);
      gate.complete();
      await Future.wait([first, joined]);
      await coordinator.refreshNow();
      expect(calls, 2);
    },
  );
}
