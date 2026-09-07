import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/external_url_launcher.dart';

/// 作者与项目信息（唯一来源）。
const String kAppAuthor = 'FHfanshu';
const String kAppAuthorEmail = '3357264605@qq.com';
const String kAppAuthorProfileUrl = 'https://github.com/FHfanshu';
const String kAppProjectUrl = 'https://github.com/FHfanshu/ZJXU-CampusHub';

/// 「关于」页：作者联系方式与 APK 分发地址（项目未开源）。
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppAppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _GroupCard(
            children: [
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final version = snapshot.hasData
                      ? 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                      : '';
                  return _Row(
                    icon: Icons.info_outline,
                    title: '嘉兴大学',
                    subtitle: version.isEmpty ? '读取版本中…' : version,
                  );
                },
              ),
              const _Hairline(),
              _Row(
                icon: Icons.person_outline,
                title: '开发者',
                subtitle: kAppAuthor,
                onTap: () => _open(kAppAuthorProfileUrl),
              ),
              const _Hairline(),
              _Row(
                icon: Icons.mail_outline,
                title: '联系邮箱',
                subtitle: kAppAuthorEmail,
                onTap: () => _open('mailto:$kAppAuthorEmail'),
              ),
              const _Hairline(),
              _Row(
                icon: Icons.link_outlined,
                title: '发布页',
                subtitle: kAppProjectUrl,
                onTap: () => _open(kAppProjectUrl),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '本项目为个人第三方开发者维护的校园工具应用，与嘉兴大学官方无关。'
              '发布页仅用于分发安装包，项目暂未开源。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.cardBorder,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 1,
      thickness: 1,
      indent: 64,
      color: cs.outlineVariant.withValues(alpha: 0.35),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Icon(icon, size: 22, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
