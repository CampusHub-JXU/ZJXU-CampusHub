import 'package:dio/dio.dart';

extension CancelTokenX on CancelToken? {
  /// 已取消则抛出该 token 的 `cancelError`；null token 视为未取消。
  void throwIfCancelled() {
    final token = this;
    if (token != null && token.isCancelled) throw token.cancelError!;
  }
}
