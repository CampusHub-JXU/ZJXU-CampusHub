import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/external_url_launcher.dart';
import '../../shared/widgets/plain_list.dart';

/// 作者与项目信息（唯一来源）。
const String kAppAuthor = 'FHfanshu';
const String kAppAuthorEmail = '3357264605@qq.com';
const String kAppAuthorProfileUrl = 'https://github.com/FHfanshu';
const String kAppProjectUrl = 'https://github.com/FHfanshu/ZJXU-CampusHub';

/// 关于页头像资源：应用图标（由 `tools/brand/app_icon_master.png` 缩放）与
/// 作者 GitHub 头像（随包分发，不在运行时联网拉取）。
const String kAppIconAsset = 'assets/brand/app_icon.png';
const String kAppAuthorAvatarAsset = 'assets/brand/author_avatar.jpg';

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

  Widget _buildHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 20),
      child: Row(
        children: [
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(20),
            child: Image.asset(kAppIconAsset, width: 76, height: 76),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '嘉兴大学',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final info = snapshot.data;
                    return Text(
                      info == null
                          ? ' '
                          : 'v${info.version}+${info.buildNumber}',
                      key: const Key('about_version'),
                      style: textTheme.titleMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthor(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        label: '开发者 $kAppAuthor',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(kAppAuthorProfileUrl),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircleAvatar(
                  radius: 30,
                  backgroundImage: AssetImage(kAppAuthorAvatarAsset),
                ),
                const SizedBox(height: 8),
                Text(kAppAuthor, style: context.appText.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          _buildHeader(context),
          Text('个人开发的第三方校园工具，与嘉兴大学官方无关。', style: context.appText.secondary),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('开发者'),
          _buildAuthor(context),
          const SizedBox(height: kPlainListGroupGap),
          PlainListGroup(
            children: [
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
        ],
      ),
    );
  }
}
