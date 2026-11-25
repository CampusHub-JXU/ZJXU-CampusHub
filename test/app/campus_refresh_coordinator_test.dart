import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/campus_refresh_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/route_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'resume invalidates both the resolver cache and the active route lease',
    () async {
      final resolver = ConnectModeResolver.instance;
      addTearDown(resolver.debugReset);
      final gate = RouteGate();
      final target = Uri.parse(ZhengfangAuth.directAcademicServiceUrl);
      var verdict = RouteVerdict.webVpnRedirected;
      var probes = 0;
      resolver.directVerdictChecker = (_) async {
        probes++;
        return verdict;
      };
      final selected = <ZhengfangMode>[];
      final coordinator = CampusRefreshCoordinator(
        ready: () => true,
        refresh: () async {
          selected.add((await gate.acquire(target)).mode);
        },
      );
      addTearDown(coordinator.dispose);
      await coordinator.refreshNow();
      coordinator.setForeground(false);
      verdict = RouteVerdict.direct;
      coordinator.setForeground(true);
      await coordinator.refreshNow();

      expect(selected, [ZhengfangMode.webVpn, ZhengfangMode.direct]);
      expect(probes, 2);
    },
  );

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
