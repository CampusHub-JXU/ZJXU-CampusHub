import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/library/library_models.dart';
import 'package:jxu_campus_hub/features/library/library_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

/// 2026-09-12 设备实测的真实响应形状。
const _detailJson = <String, Object?>{
  'bid': '0001123876',
  'callNo': 'TS974.14/51',
  'total': 4,
  'count': 4,
  'libraries': <Object?>[
    <String, Object?>{
      'group': '0011',
      'groupName': '嘉兴学院图书馆',
      'location': '00088',
      'locationName': '密集书库',
      'count': 4,
      'total': 4,
      'cids': <String>['A2470655', 'A2470656'],
      'shelfNo': 'L0001845',
    },
  ],
  'isLogin': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
  });

  test('fetchBookDetail 请求补零 bid 并解析馆藏', () async {
    final adapter = MockHttpClientAdapter();
    adapter.register('GET', '/book/detail', (options) async {
      expect(options.queryParameters['bid'], '0001123876');
      expect(options.queryParameters['orgId'], 101);
      expect(options.queryParameters['schoolId'], 0);
      return ResponseBody.fromString(
        jsonEncode(_detailJson),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    final detail = await LibraryService.instance.fetchBookDetail('1123876');

    expect(adapter.requestLog, <String>['GET /book/detail']);
    expect(detail.bid, '0001123876');
    expect(detail.callNo, 'TS974.14/51');
    expect(detail.hasAvailable, isTrue);
    expect(detail.libraries, hasLength(1));
    final holding = detail.libraries.single;
    expect(holding.locationName, '密集书库');
    expect(holding.count, 4);
    expect(holding.cids, <String>['A2470655', 'A2470656']);
    expect(holding.hasAvailable, isTrue);
    expect(detail.summary, '密集书库 4/4 · 索书号 L0001845');
  });

  test('fetchBookDetail 对空书目号抛 LibraryApiException', () async {
    expect(
      () => LibraryService.instance.fetchBookDetail('  '),
      throwsA(isA<LibraryApiException>()),
    );
  });

  test('fetchBookDetail 解析失败时抛 LibraryApiException', () async {
    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/book/detail', <String, Object?>{'foo': 1});
    DioClient.instance.dio.httpClientAdapter = adapter;

    expect(
      () => LibraryService.instance.fetchBookDetail('1123876'),
      throwsA(isA<LibraryApiException>()),
    );
  });

  test('fetchBorrows 带 Bearer 头并解析空列表', () async {
    final adapter = MockHttpClientAdapter();
    adapter.register('GET', '/user/borrows', (options) async {
      expect(options.headers['Authorization'], 'Bearer token-abc');
      expect(options.queryParameters['orgId'], 101);
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'items': <Object?>[],
          'page': 1,
          'pageSize': 20,
        }),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    });
    adapter.registerJson('GET', '/user/borrows/history', <String, Object?>{
      'items': <Object?>[
        <String, Object?>{'title': '高等数学', 'returnDate': '2026-06-01'},
      ],
      'page': 1,
      'pageSize': 20,
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    final current = await LibraryService.instance.fetchBorrows(
      accessToken: 'token-abc',
    );
    final history = await LibraryService.instance.fetchBorrows(
      accessToken: 'token-abc',
      history: true,
    );

    expect(adapter.requestLog, <String>[
      'GET /user/borrows',
      'GET /user/borrows/history',
    ]);
    expect(current.isEmpty, isTrue);
    expect(current.pageSize, 20);
    expect(history.items, hasLength(1));
    expect(history.items.single['title'], '高等数学');
  });

  test('fetchBorrows 缺凭据抛 LibraryApiException', () async {
    expect(
      () => LibraryService.instance.fetchBorrows(accessToken: ''),
      throwsA(isA<LibraryApiException>()),
    );
  });

  test('LibraryBookDetail 摘要回退到馆藏地名称', () {
    final detail = LibraryBookDetail.fromJson(<String, Object?>{
      'bid': '0001123876',
      'callNo': 'A/1',
      'total': 1,
      'count': 0,
      'libraries': <Object?>[
        <String, Object?>{
          'group': '0011',
          'groupName': '嘉兴学院图书馆',
          'location': '00001',
          'locationName': '',
          'count': 0,
          'total': 1,
          'cids': <String>[],
          'shelfNo': '',
        },
      ],
    });

    expect(detail, isNotNull);
    expect(detail!.hasAvailable, isFalse);
    expect(detail.summary, '嘉兴学院图书馆 0/1');
  });
}
