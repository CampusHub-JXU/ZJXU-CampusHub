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

  group('NetworkErrorToast.show', () {
    setUp(NetworkErrorToast.resetDedupe);

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
