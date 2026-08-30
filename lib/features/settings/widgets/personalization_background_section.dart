import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/app_dropdown.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../home/home_controller.dart';

/// 首页个性化 — 背景图片 section（PRD FR-4 拆分）。
///
/// 平面化卡面：小节标题在卡外（13/w600/onSurfaceVariant），组内行由
/// hairline 分隔（outlineVariant @ 0.35，与行文字左对齐）。
class PersonalizationBackgroundSection extends StatelessWidget {
  const PersonalizationBackgroundSection({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('背景图片'),
        const SizedBox(height: 8),
        AppCard(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: AppRadius.cardBorder,
            child: ValueListenableBuilder<String?>(
              valueListenable: HomeController.instance.backgroundImagePath,
              builder: (context, bgPath, _) {
                return Column(
                  children: [
                    _PrefRow(
                      icon: Icons.wallpaper_outlined,
                      title: '选择背景图片',
                      subtitle: bgPath != null ? '已设置自定义背景' : '未设置，使用默认背景',
                      trailing: Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: cs.onSurfaceVariant,
                      ),
                      onTap: () => _pickHomeBackgroundImage(context),
                    ),
                    if (bgPath != null) ...[
                      const _Hairline(),
                      _PrefRow(
                        icon: Icons.delete_outline,
                        title: '移除背景图片',
                        onTap: () async {
                          await HomeController.instance.setBackgroundImagePath(
                            null,
                          );
                          await HomeController.instance.setShaderEnabled(false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已移除首页背景')),
                            );
                          }
                        },
                      ),
                      const _Hairline(),
                      _buildBackgroundOpacitySlider(context),
                      const _Hairline(),
                      _buildBackgroundFitPicker(context),
                      const _Hairline(),
                      _buildBackgroundPositionControls(context),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackgroundOpacitySlider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.backgroundOpacity,
      builder: (context, opacity, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                '透明度  ${(opacity * 100).round()}%',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
            Slider.adaptive(
              value: opacity,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: HomeController.instance.setBackgroundOpacity,
            ),
          ],
        );
      },
    );
  }

  Widget _buildBackgroundFitPicker(BuildContext context) {
    return ValueListenableBuilder<HomeBackgroundFit>(
      valueListenable: HomeController.instance.backgroundFit,
      builder: (context, fit, _) {
        return _PrefRow(
          icon: Icons.fit_screen_outlined,
          title: '图片适应方式',
          subtitle: '控制背景图铺满、完整显示或拉伸方式',
          trailing: AppDropdown<HomeBackgroundFit>(
            value: fit,
            items: HomeBackgroundFit.values
                .map((item) => AppDropdownItem(value: item, label: item.label))
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              HomeController.instance.setBackgroundFit(value);
            },
          ),
        );
      },
    );
  }

  Widget _buildBackgroundPositionControls(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '在上方首页可见区域框中拖动图片调整位置，双指捏合调整缩放',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          TextButton.icon(
            onPressed: () => HomeController.instance.setBackgroundAlignment(
              Alignment.center,
            ),
            icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
            label: const Text('居中'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickHomeBackgroundImage(BuildContext context) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (picked == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final destDir = Directory('${appDir.path}/home_bg');
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      } else {
        await for (final file in destDir.list()) {
          if (file is File) {
            unawaited(file.delete().catchError((_) => file));
          }
        }
      }

      final dotIdx = picked.path.lastIndexOf('.');
      final ext = dotIdx == -1 ? '.jpg' : picked.path.substring(dotIdx);
      final destPath =
          '${destDir.path}/bg_${DateTime.now().millisecondsSinceEpoch}$ext';

      await File(picked.path).copy(destPath);
      await HomeController.instance.setBackgroundImagePath(destPath);

      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已设置首页背景')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('选择图片失败，请稍后重试')));
      }
    }
  }
}

/// 小节标题：13/w600/onSurfaceVariant。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// 组内 hairline 分隔线：outlineVariant @ 0.35，左缩进与行文字对齐。
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

/// 设置行：图标徽标 + 标题/副标题 + 右侧控件。
class _PrefRow extends StatelessWidget {
  const _PrefRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
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
              AppIconBadge(
                icon: icon,
                accentColor: cs.primary,
                size: AppIconBadgeSize.small,
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
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
