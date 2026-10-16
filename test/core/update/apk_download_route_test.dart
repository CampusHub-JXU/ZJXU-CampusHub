import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_apk_update_transport.dart';

void main() {
  group('DownloadStallDetector', () {
    final t0 = DateTime(2026, 10, 16, 12);
    DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

    test('触发连接超时：8 秒内始终 0 字节', () {
      final d = DownloadStallDetector();
      expect(d.observe(now: at(0), bytes: 0), isNull);
      for (var s = 1; s <= 7; s++) {
        expect(d.observe(now: at(s), bytes: 0), isNull, reason: 's=$s');
      }
      expect(d.observe(now: at(8), bytes: 0), ApkFallbackReason.connectTimeout);
    });

    test('已有数据后连续 10 秒无新增字节视为停滞', () {
      final d = DownloadStallDetector();
      d.observe(now: at(0), bytes: 0);
      d.observe(now: at(1), bytes: 500000);
      for (var s = 2; s <= 10; s++) {
        expect(d.observe(now: at(s), bytes: 500000), isNull, reason: 's=$s');
      }
      expect(d.observe(now: at(11), bytes: 500000), ApkFallbackReason.stalled);
    });

    test('持续低速（<100KiB/s）满 15 秒窗口触发 slow', () {
      final d = DownloadStallDetector();
      // 每秒约 50 KiB，始终有进展，不触发 stalled。
      var bytes = 0;
      ApkFallbackReason? verdict;
      for (var s = 0; s <= 30 && verdict == null; s++) {
        verdict = d.observe(
          now: at(s),
          bytes: bytes,
          totalBytes: 40 * 1024 * 1024,
        );
        bytes += 50 * 1024;
      }
      expect(verdict, ApkFallbackReason.slow);
    });

    test('正常速度（>100KiB/s）不触发', () {
      final d = DownloadStallDetector();
      var bytes = 0;
      for (var s = 0; s <= 60; s++) {
        expect(
          d.observe(now: at(s), bytes: bytes, totalBytes: 40 * 1024 * 1024),
          isNull,
          reason: 's=$s',
        );
        bytes += 400 * 1024;
      }
    });

    test('收尾小样本（剩余 <1MiB）不判低速', () {
      final d = DownloadStallDetector();
      const total = 10 * 1024 * 1024;
      var bytes = total - 512 * 1024;
      // 前 20 秒几乎不动但每秒仍有 1KiB 进展；已经在收尾区间。
      for (var s = 0; s <= 25; s++) {
        expect(
          d.observe(now: at(s), bytes: bytes, totalBytes: total),
          isNull,
          reason: 's=$s',
        );
        bytes += 1024;
      }
    });

    test('采样中断（后台）后窗口重置，不把挂起时间算作无数据', () {
      final d = DownloadStallDetector();
      d.observe(now: at(0), bytes: 0);
      d.observe(now: at(1), bytes: 1000000);
      // 60 秒后才有下一次样本（进程被冻结），字节无变化。
      expect(d.observe(now: at(61), bytes: 1000000), isNull);
      // 之后以 61 秒为新起点，仍按 10 秒无新增判停滞。
      for (var s = 62; s < 71; s++) {
        expect(d.observe(now: at(s), bytes: 1000000), isNull, reason: 's=$s');
      }
      expect(d.observe(now: at(71), bytes: 1000000), ApkFallbackReason.stalled);
    });

    test('暂停超过 12 秒触发 paused', () {
      final d = DownloadStallDetector();
      d.observe(now: at(0), bytes: 1000, paused: true);
      for (var s = 1; s < 12; s++) {
        expect(d.observe(now: at(s), bytes: 1000, paused: true), isNull);
      }
      expect(
        d.observe(now: at(12), bytes: 1000, paused: true),
        ApkFallbackReason.paused,
      );
    });

    test('reset 后重新计时', () {
      final d = DownloadStallDetector();
      d.observe(now: at(0), bytes: 0);
      d.reset();
      for (var s = 20; s < 28; s++) {
        expect(d.observe(now: at(s), bytes: 0), isNull, reason: 's=$s');
      }
      expect(
        d.observe(now: at(28), bytes: 0),
        ApkFallbackReason.connectTimeout,
      );
    });
  });

  group('ApkDownloadRoute', () {
    test('候选顺序：自动 R2→EdgeOne；无 R2 标记时只剩 EdgeOne', () {
      expect(ApkDownloadRoute.auto.candidates(r2Available: true), [
        ApkDownloadSource.r2,
        ApkDownloadSource.edgeone,
      ]);
      expect(ApkDownloadRoute.auto.candidates(r2Available: false), [
        ApkDownloadSource.edgeone,
      ]);
      expect(ApkDownloadRoute.r2.candidates(r2Available: false), isEmpty);
      expect(ApkDownloadRoute.edgeone.candidates(r2Available: true), [
        ApkDownloadSource.edgeone,
      ]);
    });

    test('ApkFallbackReason wire 名与原生白名单一致', () {
      expect(ApkFallbackReason.values.map((r) => r.name), [
        'connectTimeout',
        'stalled',
        'slow',
        'paused',
        'failed',
      ]);
    });

    test('偏好持久化：损坏值回退自动', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApkDownloadRoutePreference.storageKey: 'bogus',
      });
      expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.auto);
      await ApkDownloadRoutePreference.save(ApkDownloadRoute.edgeone);
      expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.edgeone);
    });
  });

  group('ApkDownloadStallWatcher', () {
    late FakeApkUpdateTransport transport;
    late ApkUpdateController controller;
    late DateTime now;
    late ApkDownloadStallWatcher watcher;

    setUp(() {
      transport = FakeApkUpdateTransport();
      controller = fakeApkUpdateController(transport);
      now = DateTime(2026, 10, 16, 12);
      watcher = ApkDownloadStallWatcher(
        controller: controller,
        clock: () => now,
      );
    });

    /// 推进 [seconds] 秒并模拟一次弹窗轮询：原生状态 → 控制器 → 观察器。
    Future<void> tick(
      int seconds, {
      int? bytes = 0,
      ApkUpdatePhase phase = ApkUpdatePhase.downloading,
      int attempt = 1,
      bool canSwitch = true,
    }) async {
      now = now.add(Duration(seconds: seconds));
      transport.active = ApkUpdateState(
        phase: phase,
        version: '1.2.3',
        releaseTag: 'v1.2.3',
        requestKey: 'k',
        bytesDownloaded: bytes,
        totalBytes: 40 * 1024 * 1024,
        source: ApkDownloadSource.r2,
        mode: ApkDownloadMode.auto,
        attempt: attempt,
        triedSources: const [ApkDownloadSource.r2],
        canSwitch: canSwitch,
      );
      await controller.refreshActiveUpdate();
      await watcher.onPolled();
    }

    test('8 秒无字节：只调用 switchSource(connectTimeout)', () async {
      await tick(0);
      for (var i = 0; i < 7; i++) {
        await tick(1);
      }
      expect(transport.switchCalls, 0);
      await tick(1);
      expect(transport.switchCalls, 1);
      expect(transport.switchReasons, [ApkFallbackReason.connectTimeout]);
      // 带上判定时的 attempt，原生据此丢弃换源后迟到的建议。
      expect(transport.switchAttempts, [1]);
      // 观察器不入队、不取消、不选线：这些全是原生的事。
      expect(transport.startCalls, 0);
      expect(transport.cancelCalls, 0);
    });

    test('已有数据后 10 秒无新增字节：stalled', () async {
      await tick(0);
      await tick(1, bytes: 500000);
      for (var i = 0; i < 9; i++) {
        await tick(1, bytes: 500000);
      }
      expect(transport.switchCalls, 0);
      await tick(1, bytes: 500000);
      expect(transport.switchReasons, [ApkFallbackReason.stalled]);
    });

    test('持续低速：slow', () async {
      var bytes = 0;
      for (var s = 0; s <= 30 && transport.switchCalls == 0; s++) {
        await tick(s == 0 ? 0 : 1, bytes: bytes);
        bytes += 50 * 1024;
      }
      expect(transport.switchReasons, [ApkFallbackReason.slow]);
    });

    test('暂停超过 12 秒：paused', () async {
      await tick(0, bytes: 1000, phase: ApkUpdatePhase.paused);
      for (var i = 0; i < 11; i++) {
        await tick(1, bytes: 1000, phase: ApkUpdatePhase.paused);
      }
      expect(transport.switchCalls, 0);
      await tick(1, bytes: 1000, phase: ApkUpdatePhase.paused);
      expect(transport.switchReasons, [ApkFallbackReason.paused]);
    });

    test('原生 DM 查询不可用（downloading 不带字节数）不算停滞', () async {
      await tick(0, bytes: 500000);
      for (var i = 0; i < 30; i++) {
        await tick(1, bytes: null);
      }
      expect(transport.switchCalls, 0);
    });

    test('canSwitch 为 false 时无论卡多久都不调用', () async {
      await tick(0, canSwitch: false);
      for (var i = 0; i < 60; i++) {
        await tick(1, canSwitch: false);
      }
      expect(transport.switchCalls, 0);
    });

    test('不在 enqueued / downloading / paused 的阶段不观察', () async {
      for (final phase in <ApkUpdatePhase>[
        ApkUpdatePhase.verifying,
        ApkUpdatePhase.readyToInstall,
        ApkUpdatePhase.cleanupPending,
        ApkUpdatePhase.reconcileRequired,
        ApkUpdatePhase.failed,
      ]) {
        await tick(0, phase: phase);
        for (var i = 0; i < 30; i++) {
          await tick(1, phase: phase);
        }
      }
      expect(transport.switchCalls, 0);
    });

    test('enqueued 同样按下载中观察', () async {
      await tick(0, phase: ApkUpdatePhase.enqueued);
      for (var i = 0; i < 8; i++) {
        await tick(1, phase: ApkUpdatePhase.enqueued);
      }
      expect(transport.switchReasons, [ApkFallbackReason.connectTimeout]);
    });

    test('attempt 变化即重置：新尝试重新计满 8 秒', () async {
      await tick(0);
      for (var i = 0; i < 7; i++) {
        await tick(1); // 第 1 次尝试已卡 7 秒，尚未触发。
      }
      // 原生换源后进入第 2 次尝试：计时从头开始。
      for (var i = 0; i < 8; i++) {
        await tick(1, attempt: 2);
      }
      expect(transport.switchCalls, 0, reason: '新尝试只过了 7 秒');
      await tick(1, attempt: 2);
      expect(transport.switchReasons, [ApkFallbackReason.connectTimeout]);
    });

    test('只发一次建议：原生拒绝后要再满一个完整窗口才会重试', () async {
      await tick(0);
      for (var i = 0; i < 8; i++) {
        await tick(1);
      }
      expect(transport.switchCalls, 1);
      // 原生没换（状态原样返回，canSwitch 仍为 true）：不得逐秒重复发送。
      for (var i = 0; i < 5; i++) {
        await tick(1);
      }
      expect(transport.switchCalls, 1);
    });

    test('只会发送停滞类原因，永不发送 failed', () async {
      await tick(0);
      for (var i = 0; i < 40; i++) {
        await tick(1);
      }
      expect(transport.switchReasons, isNotEmpty);
      for (final reason in transport.switchReasons) {
        expect(reason, isNot(ApkFallbackReason.failed));
      }
    });

    test('正常速度不触发', () async {
      var bytes = 0;
      for (var s = 0; s <= 60; s++) {
        await tick(s == 0 ? 0 : 1, bytes: bytes);
        bytes += 400 * 1024;
      }
      expect(transport.switchCalls, 0);
    });
  });
}
