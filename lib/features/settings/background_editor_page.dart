import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';

/// 背景编辑器入参（PRD §18）：待编辑图片绝对路径 + 当前正式状态的变换。
class BackgroundEditorArgs {
  const BackgroundEditorArgs({
    required this.imagePath,
    this.alignment = Alignment.center,
    this.scale = 1.0,
  });

  final String imagePath;
  final Alignment alignment;
  final double scale;
}

/// 编辑器确认结果；取消时 `pushNamed` 返回 null。
class BackgroundEditorResult {
  const BackgroundEditorResult({required this.alignment, required this.scale});

  final Alignment alignment;
  final double scale;
}

/// 全屏背景编辑器（PRD §18）。
///
/// 编辑状态完全独立于正式状态：拖动/捏合只改本地值，确认才回传
/// [BackgroundEditorResult]，取消不触碰用户当前设置。
class BackgroundEditorPage extends StatefulWidget {
  const BackgroundEditorPage({super.key, required this.args});

  final BackgroundEditorArgs args;

  static const phoneAspectRatio = 9 / 19.2;

  @override
  State<BackgroundEditorPage> createState() => _BackgroundEditorPageState();
}

class _BackgroundEditorPageState extends State<BackgroundEditorPage> {
  late Alignment _alignment = widget.args.alignment;
  late double _scale = widget.args.scale;

  double _startScale = 1.0;

  void _onScaleStart(ScaleStartDetails _) {
    _startScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size viewport) {
    setState(() {
      _scale = (_startScale * details.scale).clamp(0.5, 3.0);
      final dx = details.focalPointDelta.dx / (viewport.width * 0.5);
      final dy = details.focalPointDelta.dy / (viewport.height * 0.5);
      _alignment = Alignment(
        (_alignment.x + dx).clamp(-1.0, 1.0),
        (_alignment.y + dy).clamp(-1.0, 1.0),
      );
    });
  }

  void _confirm() {
    Navigator.of(context)
        .pop(BackgroundEditorResult(alignment: _alignment, scale: _scale));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, outer) {
                    final maxHeight = outer.maxHeight - 32;
                    final maxWidth = outer.maxWidth - 32;
                    var height = maxHeight;
                    var width = height * BackgroundEditorPage.phoneAspectRatio;
                    if (width > maxWidth) {
                      width = maxWidth;
                      height = width / BackgroundEditorPage.phoneAspectRatio;
                    }
                    final size = Size(width, height);
                    return _buildViewport(context, size);
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Text(
                '拖动调整位置，双指捏合调整缩放',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '取消',
            color: Colors.white,
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Text(
              '编辑背景',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: '确认',
            color: Colors.white,
            icon: const Icon(Icons.check),
            onPressed: _confirm,
          ),
        ],
      ),
    );
  }

  Widget _buildViewport(BuildContext context, Size size) {
    return GestureDetector(
      key: const ValueKey('background-editor-viewport'),
      onScaleStart: _onScaleStart,
      onScaleUpdate: (details) => _onScaleUpdate(details, size),
      child: ClipRRect(
        borderRadius: AppRadius.cardBorder,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: ColoredBox(
            color: Colors.black,
            child: Transform.translate(
              offset: Offset(
                _alignment.x * size.width * 0.5,
                _alignment.y * size.height * 0.5,
              ),
              child: Transform.scale(
                scale: _scale,
                child: Image.file(
                  File(widget.args.imagePath),
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48,
                    ),
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
