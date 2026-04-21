import 'package:dio/dio.dart';

import 'update_model.dart';

abstract interface class UpdateSource {
  Future<AppRelease> fetchLatestRelease();
}

class DisabledUpdateSource implements UpdateSource {
  const DisabledUpdateSource();

  @override
  Future<AppRelease> fetchLatestRelease() {
    throw StateError('在线更新未启用。');
  }
}

class RemoteManifestUpdateSource implements UpdateSource {
  const RemoteManifestUpdateSource({
    required this.dio,
    required this.manifestUrl,
  });

  final Dio dio;
  final String manifestUrl;

  @override
  Future<AppRelease> fetchLatestRelease() async {
    final response = await dio.get<Map<String, dynamic>>(manifestUrl);
    final data = response.data;
    if (data == null) {
      throw const FormatException('更新清单响应为空。');
    }
    return AppRelease.fromJson(data);
  }
}
