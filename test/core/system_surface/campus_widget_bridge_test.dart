import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/system_surface/campus_widget_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCampusWidgetGateway gateway;

  setUp(() {
    gateway = _FakeCampusWidgetGateway();
    CampusWidgetBridge.instance.setGatewayForTesting(gateway);
  });

  tearDown(() => CampusWidgetBridge.instance.setGatewayForTesting(null));

  test('pushSnapshot 把展示投影原样交给网关', () async {
    await CampusWidgetBridge.instance.pushSnapshot({'a': 1});
    await CampusWidgetBridge.instance.pushSnapshot({'b': 2});

    expect(gateway.snapshots, [
      {'a': 1},
      {'b': 2},
    ]);
  });

  test('requestPin 透传尺寸并原样返回网关结果', () async {
    for (final size in CampusWidgetSize.values) {
      await CampusWidgetBridge.instance.requestPin(size);
    }
    expect(gateway.pinRequests, CampusWidgetSize.values);

    for (final result in CampusWidgetPinResult.values) {
      gateway.pinResult = result;
      expect(
        await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.small),
        result,
      );
    }
  });

  test('网关降级结果原样透传给调用方', () async {
    gateway.pinResult = CampusWidgetPinResult.unsupported;
    gateway.status = CampusWidgetStatus.unknown;
    gateway.supported = false;

    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.large),
      CampusWidgetPinResult.unsupported,
    );
    expect(
      identical(
        await CampusWidgetBridge.instance.getStatus(),
        CampusWidgetStatus.unknown,
      ),
      isTrue,
    );
    expect(await CampusWidgetBridge.instance.isSupported(), isFalse);
  });

  test('getPreview 透传尺寸与目标像素宽度并返回位图', () async {
    final png = Uint8List.fromList(const [1, 2, 3]);
    gateway.previews[CampusWidgetSize.medium] = png;

    expect(
      await CampusWidgetBridge.instance.getPreview(
        CampusWidgetSize.medium,
        widthPx: 480,
      ),
      same(png),
    );
    expect(gateway.previewRequests, [(CampusWidgetSize.medium, 480)]);
    expect(
      await CampusWidgetBridge.instance.getPreview(
        CampusWidgetSize.small,
        widthPx: 240,
      ),
      isNull,
    );
  });

  test('网关异常向调用方传播（失败映射由 JNI 网关内部完成）', () async {
    gateway.pushError = StateError('boom');
    await expectLater(
      CampusWidgetBridge.instance.pushSnapshot({'a': 1}),
      throwsStateError,
    );

    gateway.pinError = StateError('boom');
    await expectLater(
      CampusWidgetBridge.instance.requestPin(CampusWidgetSize.small),
      throwsStateError,
    );
  });

  group('CampusWidgetPinResult.fromPlatformValue', () {
    test('已知结果码映射到对应枚举', () {
      expect(
        CampusWidgetPinResult.fromPlatformValue('requested'),
        CampusWidgetPinResult.requested,
      );
      expect(
        CampusWidgetPinResult.fromPlatformValue('unsupported'),
        CampusWidgetPinResult.unsupported,
      );
      expect(
        CampusWidgetPinResult.fromPlatformValue('rejected'),
        CampusWidgetPinResult.rejected,
      );
    });

    test('未知 / 旧版返回值降级为 error', () {
      expect(
        CampusWidgetPinResult.fromPlatformValue('error'),
        CampusWidgetPinResult.error,
      );
      // 旧版原生返回 bool：不再被当作成功。
      expect(
        CampusWidgetPinResult.fromPlatformValue(true),
        CampusWidgetPinResult.error,
      );
      expect(
        CampusWidgetPinResult.fromPlatformValue(null),
        CampusWidgetPinResult.error,
      );
      expect(
        CampusWidgetPinResult.fromPlatformValue('bogus'),
        CampusWidgetPinResult.error,
      );
    });
  });

  group('CampusWidgetStatus.fromPlatformValue', () {
    test('解析数量与同步时间，非正数 / 非整数按未放置', () {
      final at = DateTime(2026, 10, 16, 9, 55);
      final status = CampusWidgetStatus.fromPlatformValue(<Object?, Object?>{
        'pinSupported': true,
        'installed': <Object?, Object?>{'small': 1, 'medium': 0, 'large': '2'},
        'lastSnapshotAtMs': at.millisecondsSinceEpoch,
      });
      expect(status.pinSupported, isTrue);
      expect(status.installedCount(CampusWidgetSize.small), 1);
      expect(status.installedCount(CampusWidgetSize.medium), 0);
      expect(status.installedCount(CampusWidgetSize.large), 0);
      expect(status.lastSnapshotAt, at);
    });

    test('非 Map / 缺字段降级为未知或空', () {
      expect(
        identical(
          CampusWidgetStatus.fromPlatformValue(null),
          CampusWidgetStatus.unknown,
        ),
        isTrue,
      );
      final empty = CampusWidgetStatus.fromPlatformValue(<Object?, Object?>{
        'lastSnapshotAtMs': 0,
      });
      expect(empty.pinSupported, isFalse);
      expect(empty.installed, isEmpty);
      expect(empty.lastSnapshotAt, isNull);
    });
  });
}

/// 记录式 CampusWidgetGateway 替身：记录入参，返回可配置结果。
class _FakeCampusWidgetGateway implements CampusWidgetGateway {
  final snapshots = <Map<String, Object?>>[];
  final pinRequests = <CampusWidgetSize>[];
  final previewRequests = <(CampusWidgetSize, int)>[];

  CampusWidgetPinResult pinResult = CampusWidgetPinResult.requested;
  CampusWidgetStatus status = CampusWidgetStatus.unknown;
  final previews = <CampusWidgetSize, Uint8List>{};
  bool supported = true;
  Object? pushError;
  Object? pinError;

  @override
  Future<void> pushSnapshot(Map<String, Object?> projection) async {
    final error = pushError;
    if (error != null) throw error;
    snapshots.add(projection);
  }

  @override
  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size) async {
    final error = pinError;
    if (error != null) throw error;
    pinRequests.add(size);
    return pinResult;
  }

  @override
  Future<CampusWidgetStatus> getStatus() async => status;

  @override
  Future<Uint8List?> getPreview(
    CampusWidgetSize size, {
    required int widthPx,
  }) async {
    previewRequests.add((size, widthPx));
    return previews[size];
  }

  @override
  Future<bool> isSupported() async => supported;
}
