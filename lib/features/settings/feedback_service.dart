import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/app_config.dart';
import '../../core/logging/app_logger.dart';

enum FeedbackType {
  bug('bug', '问题反馈'),
  feature('feature', '功能建议');

  const FeedbackType(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

enum FeedbackCampus {
  lianglin('梁林校区'),
  pinghu('平湖校区'),
  offCampus('校外 / WebVPN'),
  unspecified('不确定 / 与校区无关');

  const FeedbackCampus(this.label);

  final String label;
}

class FeedbackEnvironment {
  const FeedbackEnvironment({
    required this.appVersion,
    required this.osInfo,
    required this.buildMode,
  });

  final String appVersion;
  final String osInfo;
  final String buildMode;

  String get summary => '$appVersion · $osInfo · $buildMode';
}

class FeedbackSubmission {
  const FeedbackSubmission({
    required this.type,
    required this.title,
    required this.description,
    required this.campus,
    this.contact = '',
    this.diagnostics,
    required this.environment,
  });

  final FeedbackType type;
  final String title;
  final String description;
  final FeedbackCampus campus;
  final String contact;
  final String? diagnostics;
  final FeedbackEnvironment environment;

  Map<String, dynamic> toJson() {
    return {
      'type': type.apiValue,
      'title': title.trim(),
      'description': description.trim(),
      'campus': campus.label,
      if (contact.trim().isNotEmpty) 'contact': contact.trim(),
      'appVersion': environment.appVersion,
      'osInfo': environment.osInfo,
      'buildMode': environment.buildMode,
      if (diagnostics != null && diagnostics!.trim().isNotEmpty)
        'diagnostics': diagnostics!.trim(),
    };
  }
}

class FeedbackSubmitResult {
  const FeedbackSubmitResult({
    required this.issueNumber,
    required this.issueUrl,
  });

  final int issueNumber;
  final String issueUrl;
}

class FeedbackSubmitException implements Exception {
  const FeedbackSubmitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 负责收集脱敏运行环境并向反馈中转 Worker 提交 Issue。
///
/// 使用独立、不带校园 CookieJar 的 [Dio] 实例，避免把教务/CAS Cookie
/// 携带到外部反馈域名。
class FeedbackService {
  FeedbackService({Dio? dio, String? endpointUrl, String? clientKey})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
            ),
          ),
      _endpointUrl = endpointUrl ?? AppConfig.feedbackEndpointUrl,
      _clientKey = clientKey ?? AppConfig.feedbackClientKey;

  static const String appClientHeaderValue = 'jxu-campushub';
  static const int maxDiagnosticsChars = 25000;

  final Dio _dio;
  final String _endpointUrl;
  final String _clientKey;

  /// 收集基础运行环境信息（不含学号、姓名或网络 Cookie）。
  Future<FeedbackEnvironment> collectEnvironment() async {
    var appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = 'v${info.version}+${info.buildNumber}';
    } catch (_) {
      // 平台包信息不可用时降级为 unknown，不阻断反馈。
    }
    final osVersion = Platform.operatingSystemVersion.replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final osInfo = '${Platform.operatingSystem} $osVersion'.trim();
    final buildMode = kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug';
    return FeedbackEnvironment(
      appVersion: appVersion,
      osInfo: osInfo,
      buildMode: buildMode,
    );
  }

  /// 生成脱敏诊断日志；超出传输上限时保留末尾最新部分。
  Future<String> collectDiagnostics(String appVersion) async {
    final report = await AppLogger.instance.buildDiagnosticReport(
      appVersion: appVersion,
    );
    if (report.length <= maxDiagnosticsChars) return report;
    final tail = report.substring(report.length - maxDiagnosticsChars);
    return '[...早期日志已截断，仅保留最近 $maxDiagnosticsChars 字符]\n$tail';
  }

  /// 构造本地兜底 Markdown 文本（网络失败时供用户复制到群聊/邮件）。
  String buildFallbackMarkdown(FeedbackSubmission submission) {
    final prefix = submission.type == FeedbackType.bug ? '[Bug]' : '[建议]';
    final buffer = StringBuffer()
      ..writeln('$prefix ${submission.title.trim()}')
      ..writeln()
      ..writeln('- 类型：${submission.type.label}')
      ..writeln('- 校区：${submission.campus.label}')
      ..writeln('- 环境：${submission.environment.summary}');
    if (submission.contact.trim().isNotEmpty) {
      buffer.writeln('- 联系：${submission.contact.trim()}');
    }
    buffer
      ..writeln()
      ..writeln('### 详细说明')
      ..writeln(submission.description.trim());
    if (submission.diagnostics != null &&
        submission.diagnostics!.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('### 诊断日志')
        ..writeln('````')
        ..writeln(submission.diagnostics!.trim())
        ..writeln('````');
    }
    return buffer.toString();
  }

  Future<FeedbackSubmitResult> submit(FeedbackSubmission submission) async {
    final headers = <String, dynamic>{
      'X-App-Client': appClientHeaderValue,
      if (_clientKey.isNotEmpty) 'X-Client-Key': _clientKey,
    };

    try {
      final response = await _dio.post<dynamic>(
        _endpointUrl,
        data: submission.toJson(),
        options: Options(headers: headers),
      );
      final data = response.data;
      if (data is Map) {
        final ok = data['ok'] == true;
        final number = data['issueNumber'];
        final url = data['issueUrl'];
        if (ok && number is int && url is String && url.isNotEmpty) {
          return FeedbackSubmitResult(issueNumber: number, issueUrl: url);
        }
      }
      throw const FeedbackSubmitException('反馈服务返回格式异常，请稍后重试');
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final responseData = error.response?.data;
      final serverMessage = responseData is Map
          ? responseData['error'] as String?
          : null;
      if (serverMessage != null && serverMessage.trim().isNotEmpty) {
        throw FeedbackSubmitException(serverMessage.trim());
      }
      if (status == 429) {
        throw const FeedbackSubmitException('提交过于频繁，请稍后再试');
      }
      if (status != null && status >= 400 && status < 500) {
        throw const FeedbackSubmitException('反馈内容不符合要求，请检查标题和描述');
      }
      if (status != null && status >= 500) {
        throw const FeedbackSubmitException('反馈服务暂时不可用，可先复制内容到群里反馈');
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw const FeedbackSubmitException('连接反馈服务超时，请检查网络或稍后重试');
      }
      throw const FeedbackSubmitException('网络请求失败，可先复制反馈内容到群里或邮箱');
    }
  }
}
