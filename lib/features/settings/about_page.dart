import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/logging/app_logger.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/external_url_launcher.dart';
import '../../shared/widgets/plain_list.dart';

/// 作者与项目信息（唯一来源）。
const String kAppAuthor = 'FHfanshu';
const String kAppAuthorEmail = '3357264605@qq.com';
const String kAppAuthorProfileUrl = 'https://github.com/FHfanshu';
const String kAppProjectUrl = 'https://github.com/FHfanshu/ZJXU-CampusHub';

/// 「关于与诊断」页：版本、作者联系方式、APK 分发地址与登录诊断日志。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = uri.scheme == 'mailto'
        ? await launchExternalUriFromWebView(uri, logPrefix: '关于页')
        : await openInExternalBrowser(url, logPrefix: '关于页');
    if (!ok) {
      AppLogger.instance.webview(LogLevel.warn, '关于页链接打开失败: $url');
    }
  }

  /// 复制本次启动以来的认证诊断轨迹（已脱敏），用于真机复现登录问题。
  Future<void> _copyAuthTrail(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(
        ClipboardData(text: AppLogger.instance.formatAuthTrail()),
      );
      AppFeedback.toastOn(messenger, '登录诊断日志已复制');
    } on PlatformException {
      AppFeedback.toastOn(messenger, '复制失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppAppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          kPlainListGutter,
          8,
          kPlainListGutter,
          32,
        ),
        children: [
          PlainListGroup(
            children: [
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  return PlainListRow(
                    title: '版本',
                    value: snapshot.hasData
                        ? 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                        : null,
                  );
                },
              ),
              PlainListRow(
                title: '开发者',
                value: kAppAuthor,
                onTap: () => _open(kAppAuthorProfileUrl),
              ),
              PlainListRow(
                title: '联系邮箱',
                value: kAppAuthorEmail,
                onTap: () => _open('mailto:$kAppAuthorEmail'),
              ),
              PlainListRow(title: '发布页', onTap: () => _open(kAppProjectUrl)),
            ],
          ),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('诊断'),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '复制登录诊断日志',
                subtitle: '已脱敏，不含密码与验证码',
                showChevron: false,
                onTap: () => _copyAuthTrail(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '个人开发的第三方校园工具，与嘉兴大学官方无关。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
