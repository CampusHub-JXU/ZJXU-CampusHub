import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_feedback.dart';

/// 图书馆登录说明（Issue 54）。
///
/// 图书馆站点（`libapp.zjxu.edu.cn`）自带「一卡通 / 卡证密码」登录页；统一认证
/// 只用于经 WebVPN 打开站点，**不是**图书馆网站的账号登录，也不会把统一认证
/// 凭据共享给图书馆。用户在统一认证成功后仍看到登录页，很容易误判为登录失败，
/// 这里用一段非阻塞、可随时打开的说明把边界讲清楚。
///
/// 纯文案，不做任何事：不代填、不保存、不注入脚本，也不读取或改写任何会话
/// 状态（全局统一认证会话、[LibrarySession] 令牌、网关 Cookie 都不碰）。
abstract final class LibraryLoginHelp {
  /// 「我的借阅」旁的 help 图标 tooltip，也是弹层标题。
  static const title = '图书馆登录说明';

  /// 核心说明：图书馆网站自带登录，统一认证只负责把网页打开。
  static const summary = '图书馆网站需要单独登录，请输入一卡通号和图书馆卡证密码；密码问题请咨询图书馆。';

  /// 看到登录页本身不能推断统一认证失效或图书馆故障。
  static const notFailureHint = '看到这个登录页是正常的，不代表统一认证失效。';

  /// 打开说明弹层：亚克力底部弹层，可滚动、点遮罩或返回键关闭；
  /// 不是首次进入强制弹窗，也不改变任何登录流程。
  static Future<void> show(BuildContext context) => AppFeedback.sheet<void>(
    context,
    builder: (_) => const LibraryLoginHelpSheet(),
  );
}

/// 说明弹层的可滚动内容。
///
/// 独立成公开 widget，方便在测试与预览里直接渲染（不必依赖弹层路由）。
class LibraryLoginHelpSheet extends StatelessWidget {
  const LibraryLoginHelpSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = context.appText;
    final cs = theme.colorScheme;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        0,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: [
        Row(
          children: [
            Icon(Icons.menu_book_outlined, size: 22, color: cs.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                LibraryLoginHelp.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(LibraryLoginHelp.summary, style: text.secondary),
        const SizedBox(height: AppSpacing.md),
        const _HelpNote(LibraryLoginHelp.notFailureHint),
        const SizedBox(height: AppSpacing.xl),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ),
      ],
    );
  }
}

/// 带 info 图标的说明行：图标与首行对齐，长文案换行不塌。
class _HelpNote extends StatelessWidget {
  const _HelpNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text, style: context.appText.meta)),
      ],
    );
  }
}
