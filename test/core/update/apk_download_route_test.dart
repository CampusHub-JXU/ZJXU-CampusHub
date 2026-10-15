import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_apk_update_transport.dart';

const String _github =
    'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
    'v1.2.3/JXU-CampusHub-v1.2.3-arm64-v8a.apk';

AppRelease _release({bool r2 = true}) => AppRelease(
  version: '1.2.3',
  changelog: '',
  downloadUrl: '',
  releaseUrl: 'https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v1.2.3',
  publishedAt: DateTime(2026, 10, 16),
  canonicalAssetUrl: _github,
  assetId: 7,
  assetFileName: 'JXU-CampusHub-v1.2.3-arm64-v8a.apk',
  assetSizeBytes: 40 * 1024 * 1024,
  assetSha256: 'a' * 64,
  r2MirrorAvailable: r2,
);

/// 按请求回显 requestKey / 线路的传输替身，便于核对「入队了哪条线路」。
class _RecordingTransport extends FakeApkUpdateTransport {
  final List<ApkUpdateRequest> requests = <ApkUpdateRequest>[];

  @override
  Future<ApkUpdateState> startDownload(ApkUpdateRequest request) async {
    startCalls++;
    lastRequest = request;
    requests.add(request);
    final state = ApkUpdateState(
      phase: ApkUpdatePhase.downloading,
      version: request.version,
      requestKey: request.requestKey,
      bytesDownloaded: 0,
    );
    active = state;
    return state;
  }
}

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

    test('偏好持久化：损坏值回退自动', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApkDownloadRoutePreference.storageKey: 'bogus',
      });
      expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.auto);
      await ApkDownloadRoutePreference.save(ApkDownloadRoute.edgeone);
      expect(await ApkDownloadRoutePreference.load(), ApkDownloadRoute.edgeone);
    });
  });

  group('ApkDownloadRouter', () {
    late _RecordingTransport transport;
    late ApkUpdateController controller;
    late DateTime now;
    late ApkDownloadRouter router;

    setUp(() {
      transport = _RecordingTransport();
      controller = fakeApkUpdateController(transport);
      now = DateTime(2026, 10, 16, 12);
      router = ApkDownloadRouter(controller: controller, clock: () => now);
    });

    Future<void> tick(int seconds, {int? bytes, ApkUpdatePhase? phase}) async {
      now = now.add(Duration(seconds: seconds));
      final current = controller.state.value;
      transport.active = ApkUpdateState(
        phase: phase ?? current.phase,
        version: current.version,
        requestKey: current.requestKey,
        bytesDownloaded: bytes ?? current.bytesDownloaded,
        totalBytes: 40 * 1024 * 1024,
      );
      await controller.refreshActiveUpdate();
      await router.onPolled(_release());
    }

    test('自动模式先入队 R2；8 秒无字节后换 EdgeOne，且只换一次', () async {
      await router.start(_release(), ApkDownloadRoute.auto);
      expect(transport.requests.single.source, ApkDownloadSource.r2);
      expect(
        transport.requests.single.assetUrl,
        'https://download.fhfanshu.xyz/v1.2.3/'
        'JXU-CampusHub-v1.2.3-arm64-v8a.apk',
      );

      await tick(0, bytes: 0);
      for (var i = 0; i < 8; i++) {
        await tick(1, bytes: 0);
      }
      expect(transport.cancelCalls, 1);
      expect(transport.requests, hasLength(2));
      final second = transport.requests.last;
      expect(second.source, ApkDownloadSource.edgeone);
      expect(second.assetUrl, 'https://edgeone.gh-proxy.org/$_github');
      expect(second.requestKey, isNot(transport.requests.first.requestKey));
      expect(
        router.status.value.lastFallback,
        ApkFallbackReason.connectTimeout,
      );
      expect(router.status.value.fellBackFrom, ApkDownloadSource.r2);
      expect(router.status.value.active, ApkDownloadSource.edgeone);

      // EdgeOne 也卡住：没有第三条线路，不再循环切换，状态置 exhausted。
      await tick(0, bytes: 0);
      for (var i = 0; i < 9; i++) {
        await tick(1, bytes: 0);
      }
      expect(transport.requests, hasLength(2));
      expect(transport.cancelCalls, 1);
    });

    test('R2 回退失败后原生报告失败：exhausted，不再入队', () async {
      await router.start(_release(), ApkDownloadRoute.auto);
      await tick(1, bytes: 0);
      for (var i = 0; i < 8; i++) {
        await tick(1, bytes: 0);
      }
      expect(transport.requests, hasLength(2));
      transport.active = ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.network,
        version: '1.2.3',
        requestKey: controller.state.value.requestKey,
      );
      await controller.refreshActiveUpdate();
      await router.onPolled(_release());
      expect(transport.requests, hasLength(2));
      expect(router.status.value.exhausted, isTrue);
    });

    test('DownloadManager 直接失败（network）立即回退', () async {
      await router.start(_release(), ApkDownloadRoute.auto);
      transport.active = ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.network,
        version: '1.2.3',
        requestKey: controller.state.value.requestKey,
      );
      await controller.refreshActiveUpdate();
      await router.onPolled(_release());
      expect(transport.requests, hasLength(2));
      expect(transport.requests.last.source, ApkDownloadSource.edgeone);
      expect(router.status.value.lastFallback, ApkFallbackReason.failed);
    });

    test('与线路无关的失败（存储不足）不触发回退', () async {
      await router.start(_release(), ApkDownloadRoute.auto);
      transport.active = ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.storageInsufficient,
        version: '1.2.3',
        requestKey: controller.state.value.requestKey,
      );
      await controller.refreshActiveUpdate();
      await router.onPolled(_release());
      expect(transport.requests, hasLength(1));
      expect(transport.cancelCalls, 0);
    });

    test('手动 R2：卡住也不静默改线', () async {
      await router.start(_release(), ApkDownloadRoute.r2);
      expect(transport.requests.single.source, ApkDownloadSource.r2);
      await tick(0, bytes: 0);
      for (var i = 0; i < 20; i++) {
        await tick(1, bytes: 0);
      }
      expect(transport.requests, hasLength(1));
      expect(transport.cancelCalls, 0);
    });

    test('手动 R2 但 Release 无 R2 标记：改用 EdgeOne 并如实标注', () async {
      await router.start(_release(r2: false), ApkDownloadRoute.r2);
      expect(transport.requests.single.source, ApkDownloadSource.edgeone);
      expect(router.status.value.fellBackFrom, ApkDownloadSource.r2);
      expect(router.status.value.exhausted, isFalse);
      expect(router.isWatching, isFalse);
    });

    test('自动模式无 R2 标记：直接 EdgeOne，无备用线路', () async {
      await router.start(_release(r2: false), ApkDownloadRoute.auto);
      expect(transport.requests.single.source, ApkDownloadSource.edgeone);
      expect(router.isWatching, isFalse);
    });

    test('用户换线重试：先取消旧请求再入队新线路', () async {
      await router.start(_release(), ApkDownloadRoute.r2);
      await router.restartWith(_release(), ApkDownloadRoute.edgeone);
      expect(transport.cancelCalls, 1);
      expect(transport.requests.last.source, ApkDownloadSource.edgeone);
    });

    test('下载完成后停止观察', () async {
      await router.start(_release(), ApkDownloadRoute.auto);
      expect(router.isWatching, isTrue);
      await tick(1, bytes: 40 * 1024 * 1024, phase: ApkUpdatePhase.verifying);
      expect(router.isWatching, isFalse);
    });
  });
}
