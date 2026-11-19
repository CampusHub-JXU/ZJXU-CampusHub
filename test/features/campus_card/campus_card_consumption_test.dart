import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_bill_gateway.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_consumption.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';

import '../../helpers/credential_store_test_ext.dart';

/// 官方账单页（mobilehall FineReport ykt.frm）真实响应的裁剪样本
/// （2026-11-19 实机抓取：`load_content_mobile` / `chart writer_out_html`）。
String _statWidget(String label, String value) {
  return jsonEncode({
    'currentPageIndex': 1,
    'reportTotalPage': 1,
    'pageContent': {
      'detail': [
        {
          'cellData': {
            'rows': [
              {
                'row': 0,
                'cells': [
                  {
                    'row': 0,
                    'col': 0,
                    'rowSpan': 1,
                    'colSpan': 3,
                    'text': label,
                  },
                ],
              },
              {
                'row': 1,
                'cells': [
                  {
                    'row': 1,
                    'col': 0,
                    'rowSpan': 1,
                    'colSpan': 1,
                    'isnumber': true,
                    'text': value,
                  },
                  {
                    'row': 1,
                    'col': 1,
                    'rowSpan': 1,
                    'colSpan': 2,
                    'showAsHtml': true,
                    'text':
                        '<span style="color:rgb(62,143,236);">$value</span>'
                        '<span style="color:rgb(179,179,179);">元</span>',
                  },
                ],
              },
            ],
          },
        },
      ],
    },
  });
}

String _recentWidget() {
  Map<String, Object?> cell(int row, int col, String text) => {
    'row': row,
    'col': col,
    'rowSpan': 1,
    'colSpan': 1,
    'text': text,
  };
  return jsonEncode({
    'currentPageIndex': 1,
    'reportTotalPage': 1,
    'pageContent': {
      'detail': [
        {
          'cellData': {
            'rows': [
              {
                'row': 0,
                'cells': [cell(0, 0, ''), cell(0, 2, '')],
              },
              {
                'row': 1,
                'cells': [
                  cell(1, 1, '消费日期'),
                  cell(1, 2, '消费地点'),
                  cell(1, 3, '消费金额'),
                ],
              },
              {
                'row': 2,
                'cells': [
                  cell(2, 1, '2026-11-16'),
                  cell(2, 2, '梅园餐厅二楼'),
                  cell(2, 3, '11'),
                ],
              },
              {
                'row': 3,
                'cells': [
                  cell(3, 1, '2026-11-14'),
                  cell(3, 2, '梅园餐厅二楼'),
                  cell(3, 3, '10'),
                ],
              },
              {
                'row': 4,
                'cells': [
                  cell(4, 1, '2026-11-12'),
                  cell(4, 2, '梅园餐厅一楼'),
                  cell(4, 3, '3.6'),
                ],
              },
            ],
          },
        },
      ],
    },
  });
}

String _pieChart() {
  return jsonEncode({
    'chartAttr': {
      'chartType': 'pie',
      'series': [
        {
          'name': '',
          'type': 'pie',
          'data': [
            {'x': '晚餐', 'y': '64.5'},
            {'x': '早餐', 'y': '3.6'},
            {'x': '中餐', 'y': '15'},
          ],
        },
      ],
    },
  });
}

String _columnChart() {
  return jsonEncode({
    'chartAttr': {
      'chartType': 'multiCharts',
      'series': [
        {
          'name': '消费金额',
          'type': 'column',
          'data': [
            {'x': '11-14', 'y': '20'},
            {'x': '11-12', 'y': '3.6'},
            {'x': '11-16', 'y': '11'},
          ],
        },
        {
          'name': '次数',
          'type': 'line',
          'data': [
            {'x': '11-14', 'y': '2'},
            {'x': '11-12', 'y': '1'},
            {'x': '11-16', 'y': '1'},
          ],
        },
      ],
    },
  });
}

CampusCardBillRawPayload _rawPayload() {
  return CampusCardBillRawPayload(
    widgets: {
      'ZTXF1': _statWidget('今 日 消 费', '0'),
      'ZTXF2': _statWidget('卡 内 余 额', '16.3'),
      'ZTXF3': _statWidget('本 周 消 费', '11'),
      'ZTXF4': _statWidget('本 月 消 费', '34.6'),
      'REPORT0': _recentWidget(),
    },
    charts: {
      'CHART0': {
        'source': '{}',
        'data': _pieChart(),
      },
      'CHART1': {
        'source': '{}',
        'data': _columnChart(),
      },
    },
  );
}

void main() {
  group('consumption summary parsing', () {
    test('parses stats, recent rows, meals and daily trend', () {
      final summary = CampusCardConsumptionSummary.parse(_rawPayload());

      expect(summary.todaySpend, 0);
      expect(summary.cardBalance, 16.3);
      expect(summary.weekSpend, 11);
      expect(summary.monthSpend, 34.6);

      expect(summary.recent, hasLength(3));
      expect(summary.recent.first.location, '梅园餐厅二楼');
      expect(summary.recent.first.amount, 11);
      expect(summary.recent.first.date, DateTime(2026, 11, 16));
      expect(summary.recent.last.location, '梅园餐厅一楼');
      expect(summary.recent.last.amount, 3.6);

      // 服务端「中餐」归一为「午餐」，并按早餐 / 午餐 / 晚餐排序。
      expect(summary.meals.map((m) => m.label), ['早餐', '午餐', '晚餐']);
      expect(summary.meals[1].amount, 15);
      expect(summary.mealPeak, 64.5);

      // 单日统计按日期升序，次数取 line 系列。
      expect(summary.dailyTrend.map((d) => d.label), [
        '11-12',
        '11-14',
        '11-16',
      ]);
      expect(summary.dailyTrend[1].amount, 20);
      expect(summary.dailyTrend[1].count, 2);
      expect(summary.dayPeak, 20);
      expect(summary.isEmpty, isFalse);
    });

    test('stat cell accepts html-wrapped numbers', () {
      final raw = CampusCardBillRawPayload(
        widgets: {'ZTXF1': _statWidget('今 日 消 费', '12.75')},
        charts: const {},
      );
      final summary = CampusCardConsumptionSummary.parse(raw);
      expect(summary.todaySpend, 12.75);
      expect(summary.recent, isEmpty);
      expect(summary.meals, isEmpty);
    });

    test('throws when every widget returns an html error page', () {
      final raw = CampusCardBillRawPayload(
        widgets: {
          'ZTXF1':
              '<!DOCTYPE html><html><body>Dec-Session_Timeout</body></html>',
          'REPORT0': '<!DOCTYPE html><html><body>error</body></html>',
        },
        charts: const {},
      );
      expect(
        () => CampusCardConsumptionSummary.parse(raw),
        throwsA(isA<CampusCardBillException>()),
      );
    });

    test('partial payload keeps parsed sections and zeroes the rest', () {
      final raw = CampusCardBillRawPayload(
        widgets: {'REPORT0': _recentWidget()},
        charts: const {},
      );
      final summary = CampusCardConsumptionSummary.parse(raw);
      expect(summary.recent, hasLength(3));
      expect(summary.todaySpend, 0);
      expect(summary.cardBalance, 0);
      expect(summary.meals, isEmpty);
      expect(summary.dailyTrend, isEmpty);
    });
  });

  group('campus card consumption service', () {
    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      AuthSessionPersistence.instance
        ..debugReset()
        ..debugDisableFileLock = true;
      UnifiedAuthService.instance.debugReset();
      CampusCardService.instance.debugReset();
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'casuser',
      );
      await CredentialStore.instance.saveUnifiedAuthSession('casuser');
      final epoch = (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.unified,
      )).epoch;
      await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
        PrivateCacheEnvelope(
          owner: 'casuser',
          updatedAt: DateTime(2026, 4, 10, 8, 0),
          epoch: epoch,
          payload: 23.5,
        ),
      );
      await CampusCardService.instance.restoreBalance();
      AuthSessionPersistence.instance
        ..debugReset()
        ..debugDisableFileLock = true;
    });

    tearDown(() {
      AuthSessionPersistence.instance
        ..debugReset()
        ..debugDisableFileLock = true;
    });

    test('caches the snapshot and reuses it without force refresh', () async {
      var calls = 0;
      CampusCardService.instance.debugConsumptionFetcher = () async {
        calls++;
        return CampusCardConsumptionSummary.parse(_rawPayload());
      };

      final first = await CampusCardService.instance.fetchConsumption();
      expect(first, isNotNull);
      expect(calls, 1);
      expect(CampusCardService.instance.cachedConsumption, isNotNull);
      expect(
        CampusCardService.instance.cachedConsumptionPreview,
        hasLength(3),
      );

      final second = await CampusCardService.instance.fetchConsumption();
      expect(second, isNotNull);
      expect(calls, 1);

      await CampusCardService.instance.fetchConsumption(forceRefresh: true);
      expect(calls, 2);
    });

    test('failure returns null and keeps the previous snapshot', () async {
      CampusCardService.instance.debugConsumptionFetcher = () async =>
          CampusCardConsumptionSummary.parse(_rawPayload());
      await CampusCardService.instance.fetchConsumption();

      CampusCardService.instance.debugConsumptionFetcher = () async {
        throw const CampusCardBillException('offline');
      };
      final failed = await CampusCardService.instance.fetchConsumption(
        forceRefresh: true,
      );
      expect(failed, isNull);
      expect(CampusCardService.instance.cachedConsumption, isNotNull);
    });

    test('remote fetch parses the raw gateway payload', () async {
      CampusCardService.instance.debugBillRawFetcher = () async =>
          _rawPayload();

      final summary = await CampusCardService.instance
          .fetchConsumptionRemote();
      expect(summary.monthSpend, 34.6);
      expect(summary.recent, hasLength(3));
    });

    test('no explicit owner means no request', () async {
      UnifiedAuthService.instance.debugReset();
      var calls = 0;
      CampusCardService.instance.debugConsumptionFetcher = () async {
        calls++;
        return null;
      };
      final summary = await CampusCardService.instance.fetchConsumption();
      expect(summary, isNull);
      expect(calls, 0);
    });

    test('logout drops the cached snapshot', () async {
      CampusCardService.instance.debugConsumptionFetcher = () async =>
          CampusCardConsumptionSummary.parse(_rawPayload());
      await CampusCardService.instance.fetchConsumption();
      expect(CampusCardService.instance.cachedConsumption, isNotNull);

      UnifiedAuthService.instance.debugSetSession(active: false);
      CampusCardService.instance.debugHandleUnifiedAuthChanged();
      expect(CampusCardService.instance.cachedConsumption, isNull);
    });
  });
}
