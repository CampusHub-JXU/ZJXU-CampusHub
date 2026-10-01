import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/campus_card/ecard_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  group('EcardService.md5Hash', () {
    test('computes correct MD5 hash', () {
      final result = EcardService.md5Hash('hello');
      expect(result, '5d41402abc4b2a76b9719d911017c592');
    });

    test('computes MD5 with pipe separator and secret key', () {
      final result = EcardService.md5Hash(
        '213544|20260409174434|ok15we1@oid8x5afd@',
      );
      expect(result, '32545e3364153de4107d5f149058e7e7');
    });

    test('computes MD5 for QR code info request', () {
      final qrCode =
          'AB4035960E1B59CC6C4AFEFD2E76C4DE7403FC5DE0B19C3FDEDE13A9C606F4A69DB97ADB104353CC7E84DA2ABC7696CAB747F464D8CB2E51EB8D3352E792F926D2ED025B9706A4FE770408207BD2170B1C310D63FA738C30,12066';
      final result = EcardService.md5Hash(
        '$qrCode|20260409174423|ok15we1@oid8x5afd@',
      );
      expect(result, '5a4f84ece9fc4b258fd5a8261910aec3');
    });
  });

  group('EcardService.generateSign', () {
    test('generates correct Sign for AccNum+Time', () {
      final sign = EcardService.generateSign(['213544', '20260409174434']);
      expect(sign, '32545e3364153de4107d5f149058e7e7');
    });

    test('generates correct Sign for IDNo+IDType+Time', () {
      final sign = EcardService.generateSign(['213544', '1', '20260409174434']);
      final expected = EcardService.md5Hash(
        '213544|1|20260409174434|ok15we1@oid8x5afd@',
      );
      expect(sign, expected);
    });

    test('generates correct Sign for QRCode+Time', () {
      final qrCode =
          'AB4035960E1B59CC6C4AFEFD2E76C4DE7403FC5DE0B19C3FDEDE13A9C606F4A69DB97ADB104353CC7E84DA2ABC7696CAB747F464D8CB2E51EB8D3352E792F926D2ED025B9706A4FE770408207BD2170B1C310D63FA738C30,12066';
      final sign = EcardService.generateSign([qrCode, '20260409174423']);
      expect(sign, '5a4f84ece9fc4b258fd5a8261910aec3');
    });
  });

  group('EcardService.studentIdToAccNum', () {
    test('strips leading zeros', () {
      expect(EcardService.studentIdToAccNum('00213544'), '213544');
    });

    test('returns same value when no leading zeros', () {
      expect(EcardService.studentIdToAccNum('213544'), '213544');
    });

    test('handles single digit', () {
      expect(EcardService.studentIdToAccNum('0001'), '1');
    });
  });

  group('EcardService.formatTime', () {
    test('formats DateTime as yyyymmddhhmmss', () {
      final dt = DateTime(2026, 4, 9, 17, 44, 34);
      expect(EcardService.formatTime(dt), '20260409174434');
    });

    test('pads single-digit months/days/hours', () {
      final dt = DateTime(2026, 1, 5, 3, 7, 9);
      expect(EcardService.formatTime(dt), '20260105030709');
    });
  });

  group('QRCodeInitResult', () {
    test('isSuccess is true when qrCode is set and no error', () {
      const result = QRCodeInitResult(accNum: '123', qrCode: 'QR');
      expect(result.isSuccess, true);
    });

    test('isSuccess is false when error is set', () {
      const result = QRCodeInitResult(error: 'failed');
      expect(result.isSuccess, false);
    });

    test('isSuccess is false when qrCode is null', () {
      const result = QRCodeInitResult(accNum: '123');
      expect(result.isSuccess, false);
    });
  });

  group('QRCodeInfoResult', () {
    test('isUsed when code is 1 and tradeAmt is non-empty', () {
      const result = QRCodeInfoResult(code: '1', tradeAmt: '5.00');
      expect(result.isUsed, true);
      expect(result.isPending, false);
    });

    test('isPending when code is 1 but tradeAmt is empty', () {
      const result = QRCodeInfoResult(code: '1');
      expect(result.isUsed, false);
      expect(result.isPending, true);
    });

    test('isPending when code is 0', () {
      const result = QRCodeInfoResult(code: '0');
      expect(result.isUsed, false);
      expect(result.isPending, true);
    });

    test('isPending when code is empty', () {
      const result = QRCodeInfoResult(code: '');
      expect(result.isPending, true);
    });
  });

  group('EcardService.initializeAndCreateQRCode 取消校验（gated transport）', () {
    setUp(() async {
      await resetTestEnvironment();
      DioClient.instance.debugCookieDirectoryPathProvider =
          (folderName) async =>
              '${Directory.systemTemp.createTempSync('ecard_test_').path}/'
              '$folderName/';
      await DioClient.instance.ensureInitialized();
    });

    test('QueryAccAuth 在途取消后，不再发送 QueryAccInfoH/GetQRCode', () async {
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.interceptors.clear();
      DioClient.instance.dio.httpClientAdapter = adapter;
      final gate = Completer<ResponseBody>();
      adapter.register('POST', '/QueryAccAuth.aspx', (_) => gate.future);

      var shouldContinue = true;
      final future = EcardService.instance.initializeAndCreateQRCode(
        '213544',
        shouldContinue: () => shouldContinue,
      );
      // 推进事件循环直到认证请求在途
      for (var i = 0; i < 20 && adapter.requestLog.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(adapter.requestLog, ['POST /QueryAccAuth.aspx']);

      // 认证在途期间“登出”
      shouldContinue = false;
      gate.complete(
        ResponseBody.fromString(
          jsonEncode({'Code': '1'}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );

      final result = await future;
      expect(result.isSuccess, isFalse);
      expect(result.error, '登录状态已变更，已取消本次取码');
      // 后续 HTTP 请求零发送
      expect(adapter.requestLog, ['POST /QueryAccAuth.aspx']);
    });

    test('缺省（不传回调）行为不变：三步全部发出并成功取码', () async {
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.interceptors.clear();
      DioClient.instance.dio.httpClientAdapter = adapter;
      adapter
        ..registerJson('POST', '/QueryAccAuth.aspx', {'Code': '1'})
        ..registerJson('POST', '/QueryAccInfoH.aspx', {
          'Code': '1',
          'AccName': '张三',
        })
        ..registerJson('POST', '/GetQRCode.aspx', {
          'Code': '1',
          'QRCode': 'abc',
        });

      final result = await EcardService.instance.initializeAndCreateQRCode(
        '213544',
      );

      expect(result.isSuccess, isTrue);
      expect(result.qrCode, 'abc');
      expect(result.accName, '张三');
      expect(adapter.requestLog, [
        'POST /QueryAccAuth.aspx',
        'POST /QueryAccInfoH.aspx',
        'POST /GetQRCode.aspx',
      ]);
    });

    test('QueryAccAuth 连接失败：initialize 返回固定可读错误，不推断校园网', () async {
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.interceptors.clear();
      DioClient.instance.dio.httpClientAdapter = adapter;
      adapter.register('POST', '/QueryAccAuth.aspx', (_) async {
        throw DioException(
          requestOptions: RequestOptions(path: '/QueryAccAuth.aspx'),
          type: DioExceptionType.connectionError,
          error: const SocketException('Connection reset by peer'),
          message: 'Connection reset by peer',
        );
      });

      final result = await EcardService.instance.initializeAndCreateQRCode(
        '213544',
      );

      expect(result.isSuccess, isFalse);
      expect(result.error, EcardService.connectionFailureMessage);
      expect(result.error, isNot(contains('校园网')));
      expect(adapter.requestLog, ['POST /QueryAccAuth.aspx']);
    });

    test('GetQRCode 超时：initialize 返回同一固定错误', () async {
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.interceptors.clear();
      DioClient.instance.dio.httpClientAdapter = adapter;
      adapter
        ..registerJson('POST', '/QueryAccAuth.aspx', {'Code': '1'})
        ..registerJson('POST', '/QueryAccInfoH.aspx', {
          'Code': '1',
          'AccName': '张三',
        })
        ..register('POST', '/GetQRCode.aspx', (_) async {
          throw DioException(
            requestOptions: RequestOptions(path: '/GetQRCode.aspx'),
            type: DioExceptionType.receiveTimeout,
          );
        });

      final result = await EcardService.instance.initializeAndCreateQRCode(
        '213544',
      );

      expect(result.isSuccess, isFalse);
      expect(result.error, EcardService.connectionFailureMessage);
    });
  });
}
