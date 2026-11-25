import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/academic/academic_exceptions.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_exceptions.dart';
import 'package:jxu_campus_hub/shared/widgets/network_error_toast.dart';

void main() {
  group('NetworkErrorToast.classify', () {
    test('connection timeout → network', () {
      final err = DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/x'),
      );
      expect(NetworkErrorToast.classify(err), NetworkErrorKind.network);
    });

    test('connection error → network', () {
      final err = DioException(
        type: DioExceptionType.connectionError,
        requestOptions: RequestOptions(path: '/x'),
      );
      expect(NetworkErrorToast.classify(err), NetworkErrorKind.network);
    });

    test('message mentions proxy → proxyConflict', () {
      final err = DioException(
        type: DioExceptionType.unknown,
        message: 'proxy handshake failed',
        requestOptions: RequestOptions(path: '/x'),
      );
      expect(NetworkErrorToast.classify(err), NetworkErrorKind.proxyConflict);
    });

    test('AcademicSessionExpired → academicAuthExpired', () {
      expect(
        NetworkErrorToast.classify(_SessionFailure()),
        NetworkErrorKind.academicAuthExpired,
      );
    });

    test('ChangxingNeedUnifiedAuthException → unifiedAuthExpired', () {
      expect(
        NetworkErrorToast.classify(ChangxingNeedUnifiedAuthException()),
        NetworkErrorKind.unifiedAuthExpired,
      );
    });

    test('CaptchaException → academicAuthExpired', () {
      expect(
        NetworkErrorToast.classify(CaptchaException('加载失败')),
        NetworkErrorKind.academicAuthExpired,
      );
    });

    test('null → generic', () {
      expect(NetworkErrorToast.classify(null), NetworkErrorKind.generic);
    });
  });

  group('NetworkErrorToast.resolveMessage 维护时段提示', () {
    final night = DateTime(2026, 11, 15, 23, 45);
    final midnight = DateTime(2026, 11, 16, 1, 30);
    final day = DateTime(2026, 11, 15, 10, 0);

    test('维护时段内 network 文案追加维护提示', () {
      final message = NetworkErrorToast.resolveMessage(
        NetworkErrorKind.network,
        now: night,
      );
      expect(message, startsWith('网络异常，请检查网络连接或切换 WLAN/流量后重试'));
      expect(message, contains('夜间维护'));
      expect(message, contains('23:30'));
    });

    test('跨零点凌晨同样追加维护提示', () {
      final message = NetworkErrorToast.resolveMessage(
        NetworkErrorKind.generic,
        now: midnight,
      );
      expect(message, contains('夜间维护'));
    });

    test('白天文案完全不变', () {
      final message = NetworkErrorToast.resolveMessage(
        NetworkErrorKind.network,
        now: day,
      );
      expect(message, '网络异常，请检查网络连接或切换 WLAN/流量后重试');
    });

    test('proxyConflict 是本机环境问题，维护时段也不追加', () {
      final message = NetworkErrorToast.resolveMessage(
        NetworkErrorKind.proxyConflict,
        now: night,
      );
      expect(message, '检测到系统代理，请在代理软件中将 *.zjxu.edu.cn 设为直连');
    });

    test('认证过期类文案在维护时段追加（夜间无法重新登录）', () {
      final message = NetworkErrorToast.resolveMessage(
        NetworkErrorKind.academicAuthExpired,
        now: night,
      );
      expect(message, contains('夜间维护'));
    });
  });

  group('NetworkErrorToast.show', () {
    setUp(() {
      NetworkErrorToast.resetDedupe();
      NetworkErrorToast.debugNow = null;
    });
    tearDown(() => NetworkErrorToast.debugNow = null);

    testWidgets('shows a snackbar once and dedupes within window', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: const SizedBox.shrink())),
      );

      final context = tester.element(find.byType(Scaffold));
      final err = DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/x'),
      );
      NetworkErrorToast.show(context, err);
      NetworkErrorToast.show(context, err);
      await tester.pump();

      expect(find.text('网络异常，请检查网络连接或切换 WLAN/流量后重试'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('维护时段内 snackbar 文案带维护提示', (tester) async {
      NetworkErrorToast.debugNow = () => DateTime(2026, 11, 15, 23, 45);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: const SizedBox.shrink())),
      );
      final context = tester.element(find.byType(Scaffold));
      NetworkErrorToast.show(
        context,
        DioException(
          type: DioExceptionType.connectionTimeout,
          requestOptions: RequestOptions(path: '/x'),
        ),
      );
      await tester.pump();

      expect(find.textContaining('夜间维护'), findsOneWidget);
      expect(find.textContaining('23:30'), findsOneWidget);
    });

    testWidgets('白天 snackbar 文案无维护提示', (tester) async {
      NetworkErrorToast.debugNow = () => DateTime(2026, 11, 15, 10, 0);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: const SizedBox.shrink())),
      );
      final context = tester.element(find.byType(Scaffold));
      NetworkErrorToast.show(
        context,
        DioException(
          type: DioExceptionType.connectionTimeout,
          requestOptions: RequestOptions(path: '/x'),
        ),
      );
      await tester.pump();

      expect(find.text('网络异常，请检查网络连接或切换 WLAN/流量后重试'), findsOneWidget);
      expect(find.textContaining('夜间维护'), findsNothing);
    });

    testWidgets('shows nothing without a ScaffoldMessenger', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.shrink(),
        ),
      );

      final context = tester.element(find.byType(SizedBox));
      NetworkErrorToast.show(
        context,
        DioException(
          type: DioExceptionType.connectionTimeout,
          requestOptions: RequestOptions(path: '/x'),
        ),
      );
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
    });
  });
}

class _SessionFailure implements Exception, AcademicSessionExpired {
  @override
  bool get automaticLoginPaused => false;

  @override
  String toString() => 'session failure';
}
