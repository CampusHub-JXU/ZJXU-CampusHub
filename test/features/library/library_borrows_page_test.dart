import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/library/library_borrows_page.dart';
import 'package:jxu_campus_hub/features/library/library_session.dart';
import 'package:jxu_campus_hub/features/library/library_token_reader.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

Map<String, Object?> _borrowItem({String renewId = 'R2026'}) =>
    <String, Object?>{
      'bookName': '高等数学',
      'author': '同济大学数学系',
      'desc': 'O13/68 · 高等教育出版社',
      'borrowTime': '2026-03-01 09:12:00',
      'endTime': '2026年06月01日',
      'infoDay': 2,
      'renewID': renewId,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    LibrarySession.instance.debugReset();
    LibraryTokenReader.debugReadOverride = (url) async => 'token-abc';
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
  });

  tearDown(() {
    LibrarySession.instance.debugReset();
    LibraryTokenReader.debugReadOverride = null;
  });

  testWidgets('优先使用 LibrarySession 缓存的令牌（不再开隐藏 WebView）', (tester) async {
    LibrarySession.instance.debugSetAccessToken('token-from-page');
    LibraryTokenReader.debugReadOverride = (url) async => null;

    final adapter = MockHttpClientAdapter();
    adapter.register('GET', '/user/borrows', (options) async {
      expect(options.headers['Authorization'], 'Bearer token-from-page');
      return ResponseBody.fromString(
        '{"items":[],"page":1,"pageSize":100}',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      const MaterialApp(home: LibraryBorrowsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('没有借阅'), findsOneWidget);
    expect(adapter.requestLog, <String>['GET /user/borrows']);
  });

  testWidgets('渲染借阅条目并显示到期提醒与续借入口', (tester) async {
    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/user/borrows', <String, Object?>{
      'items': <Object?>[_borrowItem()],
      'page': 1,
      'pageSize': 100,
      'nextUrl': '',
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      const MaterialApp(home: LibraryBorrowsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的借阅'), findsOneWidget);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('同济大学数学系'), findsOneWidget);
    expect(find.text('2 天后到期'), findsOneWidget);
    expect(find.text('2026年06月01日'), findsOneWidget);
    expect(find.text('续借'), findsOneWidget);
    expect(adapter.requestLog, <String>['GET /user/borrows']);
  });

  testWidgets('空借阅显示空状态', (tester) async {
    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/user/borrows', <String, Object?>{
      'items': <Object?>[],
      'page': 1,
      'pageSize': 100,
      'nextUrl': '',
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      const MaterialApp(home: LibraryBorrowsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('没有借阅'), findsOneWidget);
  });

  testWidgets('读不到令牌时提示先登录图书馆', (tester) async {
    LibraryTokenReader.debugReadOverride = (url) async => null;

    await tester.pumpWidget(
      const MaterialApp(home: LibraryBorrowsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('未登录图书馆'), findsOneWidget);
    expect(find.text('打开图书馆'), findsOneWidget);
  });

  testWidgets('续借成功后刷新并提示', (tester) async {
    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/user/borrows', <String, Object?>{
      'items': <Object?>[_borrowItem()],
      'page': 1,
      'pageSize': 100,
      'nextUrl': '',
    });
    adapter.register('POST', '/book/renew', (options) async {
      expect(options.headers['Authorization'], 'Bearer token-abc');
      return ResponseBody.fromString(
        '{"code":"200"}',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      const MaterialApp(home: LibraryBorrowsPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('续借'));
    await tester.pumpAndSettle();

    expect(adapter.requestLog, <String>[
      'GET /user/borrows',
      'POST /book/renew',
      'GET /user/borrows',
    ]);
    expect(find.text('续借成功'), findsOneWidget);
  });
}
