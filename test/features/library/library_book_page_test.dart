import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/library/library_book_page.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
  });

  testWidgets('原生馆藏页展示索书号、馆藏位置与可借数', (tester) async {
    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/book/detail', <String, Object?>{
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
    });
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      const MaterialApp(
        home: LibraryBookPage(bid: '1123876', title: '高等数学'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('TS974.14/51'), findsOneWidget);
    expect(find.text('密集书库'), findsOneWidget);
    expect(find.text('4 / 4'), findsNWidgets(2));
    expect(find.text('L0001845'), findsNWidgets(1));
    expect(find.text('A2470655、A2470656'), findsOneWidget);
  });

  testWidgets('接口异常时展示错误态并可重试', (tester) async {
    final adapter = MockHttpClientAdapter();
    adapter.registerJson('GET', '/book/detail', <String, Object?>{
      'code': 'book_not_exists',
    }, statusCode: 500);
    DioClient.instance.dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      const MaterialApp(home: LibraryBookPage(bid: '1123876')),
    );
    await tester.pumpAndSettle();

    expect(find.text('馆藏信息加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
