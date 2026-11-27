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
        'diagnostics': diagnostics!,
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
  static const githubIssuesUrl =
      'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues';

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
      appVersion: appVersion.length > 40
          ? appVersion.substring(0, 40)
          : appVersion,
      osInfo: osInfo.length > 120 ? osInfo.substring(0, 120) : osInfo,
      buildMode: buildMode,
    );
  }

  /// 生成脱敏诊断日志；超出传输上限时保留末尾最新部分。
  Future<String> collectDiagnostics(String appVersion) async {
    final report = redactFeedbackDiagnostics(
      await AppLogger.instance.buildDiagnosticReport(appVersion: appVersion),
    );
    if (report.length <= maxDiagnosticsChars) return report;
    const prefix = '[...早期日志已截断]\n';
    return '$prefix${report.substring(report.length - maxDiagnosticsChars + prefix.length)}';
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
      final fence =
          '`' *
          (RegExp(r'`+')
                  .allMatches(submission.diagnostics!)
                  .fold<int>(
                    3,
                    (length, match) =>
                        match[0]!.length > length ? match[0]!.length : length,
                  ) +
              1);
      buffer
        ..writeln()
        ..writeln('### 诊断日志')
        ..writeln(fence)
        ..writeln(submission.diagnostics!.trim())
        ..writeln(fence);
    }
    return buffer.toString();
  }

  Future<FeedbackSubmitResult> submit(FeedbackSubmission submission) async {
    final endpoint = Uri.tryParse(_endpointUrl);
    if (endpoint == null ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.scheme != 'https' &&
            !(kDebugMode &&
                endpoint.scheme == 'http' &&
                const [
                  'localhost',
                  '127.0.0.1',
                  '10.0.2.2',
                ].contains(endpoint.host)))) {
      throw const FeedbackSubmitException('反馈服务地址配置无效，请联系开发者');
    }
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
        if (ok &&
            number is int &&
            number > 0 &&
            url is String &&
            url == '$githubIssuesUrl/$number') {
          return FeedbackSubmitResult(issueNumber: number, issueUrl: url);
        }
      }
      throw const FeedbackSubmitException('无法确认提交结果，请先查看 GitHub 反馈列表，避免重复提交');
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final responseData = error.response?.data;
      final serverMessage =
          responseData is Map && responseData['error'] is String
          ? responseData['error'] as String
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
        throw const FeedbackSubmitException(
          '反馈服务暂时不可用，请先查看 GitHub 确认是否已提交，也可复制文本备份',
        );
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw const FeedbackSubmitException(
          '请求超时，Issue 可能已创建，请先查看 GitHub 反馈列表，避免重复提交',
        );
      }
      throw const FeedbackSubmitException(
        '无法确认提交结果，请先查看 GitHub 反馈列表，也可复制文本备份；请勿连续重试',
      );
    }
  }
}

/// Defense in depth for reports containing persisted logs from earlier versions.
/// Users still preview the report; free text is never claimed safe.
String redactFeedbackDiagnostics(String report) {
  var result = report.replaceAll(
    RegExp(
      r'(?:set-cookie|cookie|authorization|proxy-authorization)\s*[:=][^\r\n]*',
      caseSensitive: false,
    ),
    '[敏感请求头已移除]',
  );
  result = result.replaceAll(
    RegExp(
      r'''(["']?(?:password|passwd|pwd|mm|token|access_token|refresh_token|tokenid|ticket|jsessionid|username|studentid|student_id|x-app-client|x-client-key)["']?\s*[:=]\s*["']?)[^\s&;,}"']+''',
      caseSensitive: false,
    ),
    '[敏感参数已移除]',
  );
  result = result.replaceAll(
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  result = result.replaceAll(
    RegExp(r'\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b'),
    '[REDACTED]',
  );
  result = result.replaceAll(
    RegExp(r'\b[^\s@]+@[^\s@]+\.[^\s@]+\b'),
    '[邮箱已移除]',
  );
  result = result.replaceAll(RegExp(r'\d{10,18}[\dXx]?'), '[号码已移除]');
  return result;
}
