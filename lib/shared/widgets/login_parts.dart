import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';

/// 「记住账号并自动登录」勾选行，统一认证与教务登录共用。
///
/// 使用紧凑自定义行而非 [CheckboxListTile]：在窄屏（含 600 高的最小测试
/// 视口）下不会把表单顶出可视区。纯展示：勾选状态由调用方持有，
/// 点整行或点复选框都回调 [onChanged]。
class RememberAccountTile extends StatelessWidget {
  const RememberAccountTile({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: AppRadius.inputBorder,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Checkbox(
                  value: value,
                  onChanged: (next) => onChanged(next ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '记住账号并自动登录',
                  style: tt.bodyMedium?.copyWith(color: cs.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 验证码输入框 + 可点击刷新的验证码图块，统一认证与教务登录共用。
///
/// 纯展示：不持有验证码/ challenge 状态。两处调用只在提示文案、控制器与
/// 刷新回调上不同，验证码位数（CAS 4 / 正方 6）不在此处校验。刷新在
/// [loading]（正在提交）或 [captchaLoading]（正在取码）时禁用，无障碍 tap
/// 与 InkWell 点击保持一致。
class CaptchaRow extends StatelessWidget {
  const CaptchaRow({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.bytes,
    required this.loading,
    required this.captchaLoading,
    required this.hasError,
    required this.onRefresh,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// 当前验证码图片；为空时按 [hasError] / [captchaLoading] 显示重试图标或转圈。
  final Uint8List? bytes;

  /// 正在提交登录。
  final bool loading;

  /// 正在加载验证码。
  final bool captchaLoading;

  /// 页面存在错误提示（无图且非加载中时显示重试图标）。
  final bool hasError;

  final VoidCallback onRefresh;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final VoidCallback? refresh = (loading || captchaLoading)
        ? null
        : onRefresh;
    final image = bytes;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            decoration: InputDecoration(
              hintText: hintText,
              prefixIcon: const Icon(Icons.shield_outlined),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmitted(),
          ),
        ),
        const SizedBox(width: 12),
        Semantics(
          button: true,
          label: '刷新验证码',
          // 内层 InkWell 关闭了自身语义，这里补上等价的 tap 动作（含加载态
          // 禁用分支），避免无障碍服务只播报按钮却无法激活刷新。
          onTap: refresh,
          child: SizedBox(
            width: 140,
            height: 72,
            child: Material(
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: AppRadius.inputBorder,
                side: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                  width: 0.8,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: refresh,
                excludeFromSemantics: true,
                child: image != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Image.memory(
                          image,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                        ),
                      )
                    : (hasError && !captchaLoading)
                    ? Icon(Icons.refresh, color: cs.error, size: 24)
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
