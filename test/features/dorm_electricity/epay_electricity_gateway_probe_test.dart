import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/dorm_electricity/epay_electricity_gateway.dart';

void main() {
  group('EpayReadyProbe.parse', () {
    test('接受 iOS 形态：直接给 Map', () {
      final probe = EpayReadyProbe.parse(<Object?, Object?>{
        'token': true,
        'uuid': true,
        'cleaned': true,
        'ts': 1756000000000,
      });

      expect(probe, isNotNull);
      expect(probe!.hasToken, isTrue);
      expect(probe.hasUuid, isTrue);
      expect(probe.credentialsCleared, isTrue);
      expect(probe.tokenTimestamp, 1756000000000);
    });

    test('解开 Android 形态：JSON 字符串被再包一层引号', () {
      // evaluateJavascript 在 Android 上返回的是 JSON 编码后的字符串。
      final probe = EpayReadyProbe.parse(
        '"{\\"token\\":true,\\"uuid\\":true,\\"cleaned\\":true,\\"ts\\":1756000000123}"',
      );

      expect(probe, isNotNull);
      expect(probe!.hasToken, isTrue);
      expect(probe.hasUuid, isTrue);
      expect(probe.credentialsCleared, isTrue);
      expect(probe.tokenTimestamp, 1756000000123);
    });

    test('凭据缺位时判为未就绪（不抢跑）', () {
      expect(
        EpayReadyProbe.parse(<Object?, Object?>{
          'token': true,
          'uuid': false,
          'cleaned': true,
          'ts': 1756000000000,
        })!.hasUuid,
        isFalse,
      );
      expect(
        EpayReadyProbe.parse(<Object?, Object?>{
          'token': false,
          'uuid': true,
          'cleaned': true,
          'ts': 1756000000000,
        })!.hasToken,
        isFalse,
      );
    });

    test('时间戳缺失时按 0 处理，便于判定为遗留凭据', () {
      final probe = EpayReadyProbe.parse(<Object?, Object?>{
        'token': true,
        'uuid': true,
        'cleaned': false,
      });

      expect(probe!.tokenTimestamp, 0);
      expect(probe.credentialsCleared, isFalse);
    });

    test('无法解析的返回值当作未就绪', () {
      expect(EpayReadyProbe.parse(''), isNull);
      expect(EpayReadyProbe.parse('not json'), isNull);
      expect(EpayReadyProbe.parse(null), isNull);
      expect(EpayReadyProbe.parse(42), isNull);
    });
  });
}
