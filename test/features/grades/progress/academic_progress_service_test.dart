import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/grades/progress/academic_progress_service.dart';

import '../../../helpers/mock_http_client_adapter.dart';
import '../../../helpers/test_setup.dart';
import '../../../helpers/credential_store_test_ext.dart';

const _index = '/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html';
const _kcxx = '/jwglxt/xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html';
const _fkcxx = '/jwglxt/xsxy/xsxyqk_cxJxzxjhxfyqFKcxx.html';

ResponseBody _json(Object? data) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json;charset=UTF-8'],
  },
);

ResponseBody _html(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture = File(
    'test/fixtures/academic_progress/xsxyqk_index_excerpt.html',
  ).readAsStringSync();

  setUp(() async {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationSupportDirectory') {
        return Directory.systemTemp.path;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(pathProviderChannel, null),
    );
    await resetTestEnvironment();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
  });

  Future<void> login(String account) async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: account);
    await CredentialStore.instance.saveZhengfangSession(account);
  }

  test('GET 首页后对每个末节点串行请求课程，按 jdkcsx 选端点', () async {
    await login('2020000000');
    final bodies = <String>[];
    final adapter = MockHttpClientAdapter();
    adapter.register('GET', _index, (options) async {
      expect(options.uri.queryParameters['gnmkdm'], 'N105515');
      expect(options.uri.queryParameters['su'], '2020000000');
      return _html(fixture);
    });
    adapter.register('POST', _kcxx, (options) async {
      final body = options.data as String;
      bodies.add('Kcxx $body');
      expect(options.uri.queryParameters['gnmkdm'], 'N105515');
      expect(options.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(body, isNot(contains('xh_id')));
      if (body.startsWith('xfyqjd_id=2F7FB60CC2808277E063150B0A0A612B&')) {
        return _json([
          {'KCMC': '体育1', 'XDZT': '4', 'KCZT': 1, 'XF': '1.0', 'CJ': '70'},
          {'KCMC': '体育3', 'XDZT': '3', 'KCZT': 1, 'XF': '1'},
        ]);
      }
      if (body.startsWith('xfyqjd_id=qtkcxfyq&')) {
        return _json([
          {'KCMC': '高等数学CⅠ', 'XDZT': '4', 'XF': '4.0', 'SFJHKC': '否'},
        ]);
      }
      return _json(<Object>[]);
    });
    adapter.register('POST', _fkcxx, (options) async {
      bodies.add('FKcxx ${options.data}');
      return _json([
        {'KCMC': '3D打印', 'XDZT': '4', 'KCZT': '1', 'XF': '2.0'},
      ]);
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    final report = await AcademicProgressService.instance.fetchReport();

    expect(adapter.requestLog.first, 'GET $_index');
    expect(adapter.requestLog, hasLength(1 + 5));
    expect(bodies.map((b) => b.split(' ').first), [
      'Kcxx',
      'Kcxx',
      'FKcxx',
      'FKcxx',
      'Kcxx',
    ]);
    expect(
      bodies.first,
      'Kcxx xfyqjd_id=2F7FB60CC2808277E063150B0A0A612B&cjlrxn=2026'
      '&cjlrxq=3&bkcjlrxn=2026&bkcjlrxq=3&xscjcxkz=0&cjcxkzzt=0'
      '&cjztkz=0&cjzt=',
    );

    expect(report.summary.gpa, '3.000');
    final other = report.roots.first.children.first.children.first;
    expect(other.courses.map((c) => c.courseName), ['体育1', '体育3']);
    expect(other.courseTotal, 2);
    final others = report.roots[1];
    expect(others.courses.single.inPlan, isFalse);
    expect(others.passedTotal, 1);
    expect(report.allCourses, hasLength(2 + 2 + 1));
    expect(AcademicProgressService.instance.cachedReport, isNotNull);
  });

  test('首页结构无法识别时不发课程请求、不写缓存', () async {
    await login('2020000000');
    final adapter = MockHttpClientAdapter();
    adapter.register('GET', _index, (_) async => _html('<html></html>'));
    DioClient.instance.dio.httpClientAdapter = adapter;

    await expectLater(
      AcademicProgressService.instance.fetchReport(),
      throwsA(isA<AcademicProgressRequestException>()),
    );
    expect(adapter.requestLog, ['GET $_index']);
    expect(AcademicProgressService.instance.cachedReport, isNull);
  });

  test('课程响应不是数组时整份失败', () async {
    await login('2020000000');
    final adapter = MockHttpClientAdapter();
    adapter.register('GET', _index, (_) async => _html(fixture));
    adapter.register('POST', _kcxx, (_) async => _json({'items': []}));
    DioClient.instance.dio.httpClientAdapter = adapter;

    await expectLater(
      AcademicProgressService.instance.fetchReport(),
      throwsA(isA<AcademicProgressRequestException>()),
    );
    expect(AcademicProgressService.instance.cachedReport, isNull);
  });

  test('未登录不发请求', () async {
    final adapter = MockHttpClientAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;

    expect(
      () => AcademicProgressService.instance.fetchReport(),
      throwsA(isA<AcademicProgressAuthExpiredException>()),
    );
    expect(adapter.requestLog, isEmpty);
  });
}
