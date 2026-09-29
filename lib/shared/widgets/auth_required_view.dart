import 'package:flutter/material.dart';

import 'app_state_view_transition.dart';

class AuthRequiredView extends StatelessWidget {
  const AuthRequiredView({
    super.key,
    required this.title,
    required this.message,
    required this.buttonLabel,
    required this.onAction,
    this.icon = Icons.lock_outline,
  });

  final String title;
  final String message;
  final String buttonLabel;
  final VoidCallback onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 整块内容走统一的淡入 + 轻微上浮，避免内容 → 登录引导瞬切。
    return AppStateViewTransition(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: cs.primary, size: 28),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: onAction,
                          child: Text(buttonLabel),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 教务数据页（课表/成绩/考试）共用的未登录引导。
///
/// [automaticLoginPaused] 为 true 时切换为「需要手动登录」文案（身份失败达
/// 阈值、自动登录已暂停）；否则展示各页自己的 [title] / [message]。
class AcademicLoginRequiredView extends StatelessWidget {
  const AcademicLoginRequiredView({
    super.key,
    required this.automaticLoginPaused,
    required this.title,
    required this.message,
    required this.onAction,
    this.icon = Icons.school_outlined,
  });

  static const pausedTitle = '需要手动登录';
  static const pausedMessage = '自动登录已暂停（多次登录失败），请手动登录一次；登录成功后会自动重新开启自动登录。';

  final bool automaticLoginPaused;
  final String title;
  final String message;
  final VoidCallback onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) => AuthRequiredView(
    title: automaticLoginPaused ? pausedTitle : title,
    message: automaticLoginPaused ? pausedMessage : message,
    buttonLabel: '登录教务系统',
    onAction: onAction,
    icon: icon,
  );
}
