import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/features/campus_card/epay_payment_code_service.dart';

class _FakeGateway implements Epay100Gateway {
  _FakeGateway({
    this.settingsBody,
    this.qrcodeBody,
    this.settingsError,
    this.qrcodeError,
  });

  final List<({String method, Map<String, String> data})> calls = [];

  final String? settingsBody;
  final String? qrcodeBody;
  final Object? settingsError;
  final Object? qrcodeError;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    calls.add((method: method, data: Map<String, String>.of(data)));
    if (method == 'app.yktservice.getSetting') {
      if (settingsError != null) throw settingsError!;
      return settingsBody!;
    }
    if (method == 'app.yktservice.getPayQrcode') {
      if (qrcodeError != null) throw qrcodeError!;
      return qrcodeBody!;
    }
    throw StateError('unexpected method: $method');
  }

  @override
  Future<void> invalidate() async {}

  @override
  void debugReset() {}
}

/// 官方响应的配置位于 data.mod_settings 之下；page_settings 可能不在裁剪后的
/// 响应中，enable_settings 不能替代 page_settings。
const _verifiedModSettings = {
  'basic_settings': {'paycode_refresh_time': 60, 'pay_code_type': 2},
  'enable_settings': {'pay_code_enabled': false},
};
const _verifiedQrcodeData = {
  'status': '0',
  'qrcode': '1234567890|20260906|TX',
  'short_qrcode': 'AB12CD',
  'tag': 'ykt_zhengyuan5.0',
  'percode': '0001234567',
  'status_name': '待核销',
};

String settingsEnvelope({Object? mod = _verifiedModSettings}) {
  return jsonEncode({
    'code': '200',
    'msg': 'SUC0000',
    'data': {'mod_settings': mod},
  });
}

String qrcodeEnvelope({Object? data = _verifiedQrcodeData}) {
  return jsonEncode({'code': '200', 'msg': 'SUC0000', 'data': data});
}

Future<Duration> refreshWithMod(Object? mod) async {
  final gateway = _FakeGateway(
    settingsBody: settingsEnvelope(mod: mod),
    qrcodeBody: qrcodeEnvelope(),
  );
  return (await EpayPaymentCodeService(gateway: gateway).fetch()).refreshAfter;
}

void main() {
  group('EpayPaymentCodeService', () {
    test('正常路径：先取配置再取码，参数与实测协议一致', () async {
      final gateway = _FakeGateway(
        settingsBody: settingsEnvelope(),
        qrcodeBody: qrcodeEnvelope(),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      final result = await service.fetch();

      expect(result.qrcode, _verifiedQrcodeData['qrcode']);
      expect(result.refreshAfter, const Duration(seconds: 60));
      expect(gateway.calls.map((c) => c.method).toList(), [
        'app.yktservice.getSetting',
        'app.yktservice.getPayQrcode',
      ]);
      expect(gateway.calls[0].data, isEmpty);
      expect(gateway.calls[1].data, {
        'withhold_pay_type': 'pay_yktpay',
        'refresh': '1',
      });
    });

    test('缺少 page_settings 时按官方 false 分支正常取码', () async {
      expect(
        await refreshWithMod({
          'basic_settings': {'paycode_refresh_time': 45},
          'enable_settings': {'pay_code_enabled': false},
        }),
        const Duration(seconds: 45),
      );
    });

    test('正数小于 10 尊重服务端值，不向上 clamp；上限 60 秒', () async {
      Object? modWith(int seconds) => {
        'basic_settings': {'paycode_refresh_time': seconds},
        'page_settings': {'pay_select_enabled': false},
      };

      expect(await refreshWithMod(modWith(5)), const Duration(seconds: 5));
      expect(await refreshWithMod(modWith(1)), const Duration(seconds: 1));
      expect(await refreshWithMod(modWith(300)), const Duration(seconds: 60));
    });

    test('refresh_time 缺失 / 无效时默认 60 秒', () async {
      expect(
        await refreshWithMod({
          'page_settings': {'pay_select_enabled': false},
        }),
        const Duration(seconds: 60),
      );
      expect(
        await refreshWithMod({
          'basic_settings': {'paycode_refresh_time': 'abc'},
          'page_settings': {'pay_select_enabled': false},
        }),
        const Duration(seconds: 60),
      );
      expect(
        await refreshWithMod({
          'basic_settings': {'paycode_refresh_time': 0},
          'page_settings': {'pay_select_enabled': false},
        }),
        const Duration(seconds: 60),
      );
    });

    test('嵌套 pay_select_enabled=true：拒绝出码并提示官方页，不取码', () async {
      final gateway = _FakeGateway(
        settingsBody: settingsEnvelope(
          mod: {
            'basic_settings': {'paycode_refresh_time': 60},
            'page_settings': {'pay_select_enabled': true},
          },
        ),
        qrcodeBody: qrcodeEnvelope(),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(
          isA<EpayGatewayException>().having(
            (e) => e.message,
            'message',
            contains('官方'),
          ),
        ),
      );
      expect(gateway.calls, hasLength(1));
      expect(
        EpayPaymentCodeService.officialUrl,
        'https://www.epay100.cn/901/6279/cardService/PayCode',
      );
    });

    test('mod_settings/page_settings 缺失时使用官方默认，不阻断正常响应', () async {
      final missingMod = _FakeGateway(
        settingsBody: settingsEnvelope(mod: null),
        qrcodeBody: qrcodeEnvelope(),
      );
      await expectLater(
        EpayPaymentCodeService(gateway: missingMod).fetch(),
        completes,
      );

      await expectLater(
        refreshWithMod({
          'basic_settings': {'paycode_refresh_time': 60},
          'enable_settings': {'pay_code_enabled': false},
        }),
        completes,
      );
    });

    test('getSetting 信封错误不可吞，直接失败且不取码', () async {
      final gateway = _FakeGateway(
        settingsBody: jsonEncode({
          'code': '500',
          'msg': 'SYSTEM_ERROR',
          'data': null,
        }),
        qrcodeBody: qrcodeEnvelope(),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(
          isA<EpayGatewayException>().having(
            (e) => e.message,
            'message',
            'SYSTEM_ERROR',
          ),
        ),
      );
      expect(gateway.calls, hasLength(1));
    });

    test('getSetting C900901 透传绑定异常，不取码、不当登录过期', () async {
      final gateway = _FakeGateway(
        settingsError: const EpayBindingRequiredException(),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(isA<EpayBindingRequiredException>()),
      );
      expect(gateway.calls, hasLength(1));
      expect(gateway.calls.single.method, 'app.yktservice.getSetting');
    });

    test('getPayQrcode C900901 透传绑定异常', () async {
      final gateway = _FakeGateway(
        settingsBody: settingsEnvelope(),
        qrcodeError: const EpayBindingRequiredException(),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(
          isA<EpayBindingRequiredException>().having(
            (e) => e.message,
            'message',
            EpayBindingRequiredException.defaultMessage,
          ),
        ),
      );
    });

    test('getSetting 网关异常（如会话不可用）向上传递', () async {
      final gateway = _FakeGateway(
        settingsError: const EpaySessionUnavailableException('请先登录'),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(isA<EpaySessionUnavailableException>()),
      );
      expect(gateway.calls, hasLength(1));
    });

    test('空码必须抛安全异常，异常信息不携带响应内容', () async {
      final gateway = _FakeGateway(
        settingsBody: settingsEnvelope(),
        qrcodeBody: qrcodeEnvelope(
          data: {
            'status': '0',
            'qrcode': '',
            'short_qrcode': '',
            'tag': 'ykt_zhengyuan5.0',
          },
        ),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(
          isA<EpayGatewayException>().having(
            (e) => e.message,
            'message',
            '付款码获取失败，请稍后重试',
          ),
        ),
      );
    });

    test('业务码非 200：透传服务端 msg', () async {
      final gateway = _FakeGateway(
        settingsBody: settingsEnvelope(),
        qrcodeBody: jsonEncode({'code': 'C900903', 'msg': '客户端识别码已失效'}),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(
          isA<EpayGatewayException>().having(
            (e) => e.message,
            'message',
            '客户端识别码已失效',
          ),
        ),
      );
    });

    test('信封无法解析 / data 缺失：抛安全异常', () async {
      final malformed = _FakeGateway(
        settingsBody: settingsEnvelope(),
        qrcodeBody: '<html>login</html>',
      );
      await expectLater(
        EpayPaymentCodeService(gateway: malformed).fetch(),
        throwsA(isA<EpayGatewayException>()),
      );

      final noData = _FakeGateway(
        settingsBody: settingsEnvelope(),
        qrcodeBody: jsonEncode({'code': '200', 'msg': 'SUC0000', 'data': null}),
      );
      await expectLater(
        EpayPaymentCodeService(gateway: noData).fetch(),
        throwsA(isA<EpayGatewayException>()),
      );
    });

    test('取码阶段会话不可用向上传递，供 UI 引导重新登录', () async {
      final gateway = _FakeGateway(
        settingsBody: settingsEnvelope(),
        qrcodeError: const EpaySessionUnavailableException(),
      );
      final service = EpayPaymentCodeService(gateway: gateway);

      await expectLater(
        service.fetch(),
        throwsA(isA<EpaySessionUnavailableException>()),
      );
    });
  });
}
