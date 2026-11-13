import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/theme/personalization_controller.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/plain_list.dart';
import '../background_editor_page.dart';

/// 分段控件暴露的三档填充方式；`fill` / `fitWidth` 不再在 UI 出现，
/// 已存这两档的用户显示为未选中，点任一档即覆盖（不做迁移）。
const List<(HomeBackgroundFit, String)> kWallpaperFitSegments = [
  (HomeBackgroundFit.cover, '铺满'),
  (HomeBackgroundFit.contain, '适应'),
  (HomeBackgroundFit.none, '居中'),
];

/// 个性化 — 「壁纸」分组：更换 / 填充方式 / 不透明度 / 位置与缩放 / 移除。
class PersonalizationBackgroundSection extends StatelessWidget {
  const PersonalizationBackgroundSection({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = PersonalizationController.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlainSectionHeader('壁纸'),
        ValueListenableBuilder<String?>(
          valueListenable: controller.backgroundImagePath,
          builder: (context, bgPath, _) {
            return PlainListGroup(
              children: [
                PlainListRow(
                  key: const Key('personalization_pick_wallpaper'),
                  leading: _WallpaperThumbnail(path: bgPath),
                  title: '更换壁纸',
                  value: bgPath != null ? '自定义' : '默认',
                  onTap: () => _pickHomeBackgroundImage(context),
                ),
                const _FitSegmentsRow(),
                ValueListenableBuilder<double>(
                  valueListenable: controller.backgroundOpacity,
                  builder: (context, opacity, _) => PlainSliderRow(
                    sliderKey: const Key('personalization_bg_opacity'),
                    title: '壁纸不透明度',
                    value: opacity,
                    valueLabel: '${(opacity * 100).round()}%',
                    divisions: 20,
                    onChanged: controller.setBackgroundOpacity,
                  ),
                ),
                if (bgPath != null)
                  PlainListRow(
                    key: const Key('personalization_edit_transform'),
                    title: '调整位置与缩放',
                    onTap: () => _editWallpaperTransform(context, bgPath),
                  ),
                if (bgPath != null) const _ResetTransformRow(),
                if (bgPath != null)
                  PlainListRow(
                    key: const Key('personalization_remove_wallpaper'),
                    title: '移除壁纸',
                    titleColor: Theme.of(context).colorScheme.error,
                    showChevron: false,
                    onTap: () => _removeWallpaper(context),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _editWallpaperTransform(
    BuildContext context,
    String bgPath,
  ) async {
    final controller = PersonalizationController.instance;
    final result = await context.pushNamed<BackgroundEditorResult?>(
      'background-editor',
      extra: BackgroundEditorArgs(
        imagePath: bgPath,
        alignment: controller.backgroundAlignment.value,
        scale: controller.backgroundScale.value,
      ),
    );
    if (result == null) return;
    await controller.setBackgroundAlignment(result.alignment);
    await controller.setBackgroundScale(result.scale);
  }

  Future<void> _removeWallpaper(BuildContext context) async {
    final controller = PersonalizationController.instance;
    await controller.setBackgroundImagePath(null);
    // 流体 Shader 依赖壁纸取样，移除壁纸时一并关闭。
    await controller.setShaderEnabled(false);
    if (context.mounted) {
      AppFeedback.toast(context, '已移除首页背景');
    }
  }

  Future<void> _pickHomeBackgroundImage(BuildContext context) async {
    try {
      // 保留原始图像：不设 maxWidth/maxHeight/imageQuality，避免默认重编码
      // （PRD §19）；decode 尺寸在渲染层控制。
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final destDir = Directory('${appDir.path}/home_bg');
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      }

      final dotIdx = picked.path.lastIndexOf('.');
      final ext = dotIdx == -1 ? '.jpg' : picked.path.substring(dotIdx);
      final destPath =
          '${destDir.path}/bg_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(picked.path).copy(destPath);

      if (!context.mounted) return;
      final controller = PersonalizationController.instance;

      // 全屏编辑：编辑状态独立，确认前不修改正式设置（PRD §18）。
      final result = await context.pushNamed<BackgroundEditorResult?>(
        'background-editor',
        extra: BackgroundEditorArgs(
          imagePath: destPath,
          alignment: controller.backgroundAlignment.value,
          scale: controller.backgroundScale.value,
        ),
      );

      if (result == null) {
        // 取消：丢弃新副本，保留原正式背景。
        unawaited(File(destPath).delete().catchError((_) => File(destPath)));
        return;
      }

      await controller.setBackgroundImagePath(destPath);
      await controller.setBackgroundAlignment(result.alignment);
      await controller.setBackgroundScale(result.scale);
      await _pruneOtherBackgrounds(destDir, destPath);

      if (context.mounted) {
        AppFeedback.toast(context, '已设置首页背景');
      }
    } catch (e) {
      if (context.mounted) {
        AppFeedback.toast(context, '选择图片失败，请稍后重试');
      }
    }
  }

  /// 确认后清理旧背景文件，只保留当前生效的一份。
  Future<void> _pruneOtherBackgrounds(
    Directory destDir,
    String keepPath,
  ) async {
    await for (final file in destDir.list()) {
      if (file is File && file.path != keepPath) {
        unawaited(file.delete().catchError((_) => file));
      }
    }
  }
}

/// 「填充方式」：标题在上、三档分段整行宽。
class _FitSegmentsRow extends StatelessWidget {
  const _FitSegmentsRow();

  @override
  Widget build(BuildContext context) {
    final controller = PersonalizationController.instance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPlainListRowInset,
        10,
        kPlainListRowInset,
        6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '填充方式',
            style: TextStyle(
              fontSize: 16,
              height: 1.3,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<HomeBackgroundFit>(
            valueListenable: controller.backgroundFit,
            builder: (context, fit, _) {
              final exposed = kWallpaperFitSegments.any((s) => s.$1 == fit);
              return SegmentedButton<HomeBackgroundFit>(
                key: const Key('personalization_fit_segments'),
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                segments: [
                  for (final (value, label) in kWallpaperFitSegments)
                    ButtonSegment(value: value, label: Text(label)),
                ],
                selected: exposed ? {fit} : const {},
                onSelectionChanged: (selection) {
                  // 再点已选中的一档会得到空集：保持原值。
                  if (selection.isEmpty) return;
                  controller.setBackgroundFit(selection.first);
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 「更换壁纸」行首缩略图：有壁纸显示小图，否则显示占位图标。
class _WallpaperThumbnail extends StatelessWidget {
  const _WallpaperThumbnail({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Icon(
        Icons.wallpaper_outlined,
        size: 20,
        color: cs.onSurfaceVariant,
      ),
    );
    final imagePath = path;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 40,
        child: imagePath == null
            ? placeholder
            : Image.file(
                File(imagePath),
                fit: BoxFit.cover,
                cacheWidth: 120,
                gaplessPlayback: true,
                errorBuilder: (context, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// 预览里拖动/捏合过壁纸后才出现：一键回到居中、原始缩放。
class _ResetTransformRow extends StatelessWidget {
  const _ResetTransformRow();

  @override
  Widget build(BuildContext context) {
    final controller = PersonalizationController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.backgroundAlignment,
        controller.backgroundScale,
      ]),
      builder: (context, _) {
        final moved =
            controller.backgroundAlignment.value != Alignment.center ||
            controller.backgroundScale.value != 1.0;
        if (!moved) return const SizedBox.shrink();
        return PlainListRow(
          key: const Key('personalization_reset_transform'),
          title: '复原位置与缩放',
          showChevron: false,
          onTap: () async {
            await controller.setBackgroundAlignment(Alignment.center);
            await controller.setBackgroundScale(1.0);
          },
        );
      },
    );
  }
}
