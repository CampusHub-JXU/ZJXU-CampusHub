import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/app_theme_controller.dart';
import '../../../shared/widgets/app_dropdown.dart';
import '../../home/home_controller.dart';

/// 首页个性化 — 背景图片 section（PRD FR-4 拆分）。
class PersonalizationBackgroundSection extends StatelessWidget {
  const PersonalizationBackgroundSection({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Text('背景图片', style: textTheme.titleSmall),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: HomeController.instance.backgroundImagePath,
            builder: (context, bgPath, _) {
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.wallpaper_outlined),
                    title: const Text('选择背景图片'),
                    subtitle: Text(bgPath != null ? '已设置自定义背景' : '未设置，使用默认背景'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickHomeBackgroundImage(context),
                  ),
                  if (bgPath != null) ...[
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('移除背景图片'),
                      onTap: () async {
                        await HomeController.instance.clearBackgroundImage();
                        await HomeController.instance.setShaderEnabled(false);
                        await AppThemeController.instance.refreshMonetSeed();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已移除首页背景')),
                          );
                        }
                      },
                    ),
                    _buildBackgroundOpacitySlider(),
                    _buildBackgroundFitPicker(context),
                    _buildBackgroundPositionControls(context),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundOpacitySlider() {
    return ValueListenableBuilder<double>(
      valueListenable: HomeController.instance.backgroundOpacity,
      builder: (context, opacity, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '透明度  ${(opacity * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
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
        return ListTile(
          leading: const Icon(Icons.fit_screen_outlined),
          title: const Text('图片适应方式'),
          subtitle: const Text('控制背景图铺满、完整显示或拉伸方式'),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '在上方首页可见区域框中拖动图片调整位置，双指捏合调整缩放',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
      await AppThemeController.instance.refreshMonetSeed();

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已设置首页背景')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('选择图片失败，请稍后重试')));
      }
    }
  }
}
