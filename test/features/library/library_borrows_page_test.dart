import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/library/library_borrows_page.dart';
import 'package:jxu_campus_hub/features/library/library_session.dart';
import 'package:jxu_campus_hub/features/library/library_token_reader.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

const _testAccount = 'TEST_LIB_ACCOUNT_1';

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
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: _testAccount,
    );
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

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
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

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
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

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
    await tester.pumpAndSettle();

    expect(find.text('没有借阅'), findsOneWidget);
  });

  testWidgets('读不到令牌时提示先登录图书馆', (tester) async {
    LibraryTokenReader.debugReadOverride = (url) async => null;

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
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

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
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

  testWidgets('登出后缓存令牌立即失效，不再用旧账号令牌请求', (tester) async {
    LibrarySession.instance.debugSetAccessToken('token-account-a');
    expect(LibrarySession.instance.accessToken, 'token-account-a');

    await UnifiedAuthService.instance.markLoggedOut();
    expect(LibrarySession.instance.accessToken, isNull);
    LibraryTokenReader.debugReadOverride = (url) async => null;

    final adapter = MockHttpClientAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
    await tester.pumpAndSettle();

    expect(find.text('未登录图书馆'), findsOneWidget);
    expect(adapter.requestLog, isEmpty);
  });

  testWidgets('切换账号后旧账号在途借阅结果被拒绝', (tester) async {
    LibrarySession.instance.debugSetAccessToken('token-account-a');
    final pending = Completer<ResponseBody>();
    var borrowCalls = 0;
    final adapter = MockHttpClientAdapter();
    adapter.register('GET', '/user/borrows', (options) {
      borrowCalls++;
      return pending.future;
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
    // dio 请求链经事件循环 Timer 推进：有限步进假时钟直到请求挂在闸门上。
    for (var i = 0; i < 20 && borrowCalls < 1; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(borrowCalls, 1);

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'TEST_LIB_ACCOUNT_2',
    );
    pending.complete(
      ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'items': <Object?>[_borrowItem()],
          'page': 1,
          'pageSize': 100,
        }),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsNothing);
    expect(find.text('统一认证会话已变化，请重试'), findsOneWidget);
  });

  testWidgets('401 清除缓存令牌并提示重新登录', (tester) async {
    LibrarySession.instance.debugSetAccessToken('token-stale');
    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/user/borrows', <String, Object?>{
      'code': 'invalid_access_token',
      'message': '未登录',
    }, statusCode: 401);
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
    await tester.pumpAndSettle();

    expect(find.text('图书馆登录已过期，请重新登录'), findsOneWidget);
    expect(LibrarySession.instance.accessToken, isNull);
  });

  testWidgets('下拉刷新失败时保留已有借阅列表并提示，不替换为错误页', (tester) async {
    var calls = 0;
    final adapter = MockHttpClientAdapter();
    adapter.register('GET', '/user/borrows', (options) async {
      calls++;
      if (calls == 1) {
        return ResponseBody.fromString(
          jsonEncode(<String, Object?>{
            'items': <Object?>[_borrowItem()],
            'page': 1,
            'pageSize': 100,
            'nextUrl': '',
          }),
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      }
      return ResponseBody.fromString(
        '{"message":"boom"}',
        500,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(const MaterialApp(home: LibraryBorrowsPage()));
    await tester.pumpAndSettle();
    expect(find.text('高等数学'), findsOneWidget);

    await tester.fling(find.text('高等数学'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('借阅记录加载失败'), findsNothing);
    expect(find.textContaining('刷新失败'), findsOneWidget);
  });
}
