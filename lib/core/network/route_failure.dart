import 'dart:async';

import 'package:dio/dio.dart';

bool isRouteConnectionFailure(DioException error) => switch (error.type) {
  DioExceptionType.connectionError ||
  DioExceptionType.connectionTimeout ||
  DioExceptionType.receiveTimeout ||
  DioExceptionType.sendTimeout => true,
  _ => false,
};

enum RouteFailureReason {
  connectionFailed('网络连接失败，请检查网络'),
  webVpnGatewayFailed('学校 WebVPN 暂时异常'),
  unknownRedirect('当前网络被重定向，可能需要先登录 Wi-Fi'),
  schoolBackendError('学校服务暂时不可用');

  const RouteFailureReason(this.message);

  final String message;
}

class RouteFailure extends TimeoutException {
  RouteFailure(this.reason) : super(reason.message);

  final RouteFailureReason reason;

  @override
  String toString() => reason.message;
}
