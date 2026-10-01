import 'package:flutter/foundation.dart';

class ChangxingAuthExpiredException implements Exception {
  ChangxingAuthExpiredException([this.message = '畅行嘉大登录已失效，请重新登录']);

  final String message;

  @override
  String toString() => message;
}

class ChangxingCasLoginException implements Exception {
  ChangxingCasLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// CAS session 无效，需要重新登录一卡通。
class ChangxingNeedUnifiedAuthException implements Exception {
  @override
  String toString() => '一卡通登录已失效，请重新登录';
}

@immutable
class ChangxingSubmitRequest {
  const ChangxingSubmitRequest({required this.path, required this.payload});

  final String path;
  final Map<String, dynamic> payload;
}
