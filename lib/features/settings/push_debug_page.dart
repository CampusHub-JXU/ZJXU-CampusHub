import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/push/push_service.dart';
import '../../shared/widgets/app_app_bar.dart';

class PushDebugPage extends StatelessWidget {
  const PushDebugPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final token = PushService.instance.fcmToken;

    return Scaffold(
      appBar: AppAppBar(title: const Text('推送令牌')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('FCM 推送通道', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        token != null ? Icons.check_circle : Icons.pending,
                        size: 18,
                        color: token != null ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'FCM (Firebase)',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    token ?? '未注册',
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: token != null ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (token != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: token));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制到剪贴板')),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '在 Firebase Console 中使用此令牌可向本设备发送测试推送。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
