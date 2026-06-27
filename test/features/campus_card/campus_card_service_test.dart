import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = CampusCardService.instance;

  setUp(service.debugReset);

  group('CampusCardService.parseBalanceFromPageText', () {
    test('parses amount from same line with currency sign', () {
      final balance = service.parseBalanceFromPageText('卡内余额：￥23.50 元');

      expect(balance, 23.5);
    });

    test('parses amount near balance label on adjacent line', () {
      final balance = service.parseBalanceFromPageText('''
校园卡信息
18.25 元
卡内余额
''');

      expect(balance, 18.25);
    });

    test('returns null when no balance text exists', () {
      final balance = service.parseBalanceFromPageText('当前页面没有余额字段');

      expect(balance, isNull);
    });

    test('parses balance directly from returned html', () {
      final balance = service.parseBalanceFromHtml('''
        <html><body><section><span>卡内余额</span><strong>￥36.80</strong></section></body></html>
      ''');

      expect(balance, 36.8);
    });

    test('returns null when returned html is only a report shell', () {
      final balance = service.parseBalanceFromHtml('''
        <html><head><script src="report.js"></script></head><body><div id="app"></div></body></html>
      ''');

      expect(balance, isNull);
    });

    test('coalesces concurrent balance refreshes', () async {
      final completer = Completer<double?>();
      var calls = 0;
      service.debugBalanceFetcher = () {
        calls += 1;
        return completer.future;
      };

      final first = service.fetchBalance(forceRefresh: true);
      final second = service.fetchBalance(forceRefresh: true);
      expect(calls, 1);

      completer.complete(null);
      expect(await Future.wait([first, second]), [null, null]);
      expect(calls, 1);
    });

    test('clears cached balance when refresh cannot reach balance page', () {
      service.debugSetCachedBalance(23.5, updatedAt: DateTime(2026, 6, 28));

      expect(service.clearCachedBalance(), isNull);
      expect(service.cachedBalance, isNull);
      expect(service.lastUpdated, isNull);
    });
  });
}
