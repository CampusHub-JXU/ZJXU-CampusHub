import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_icon_style.dart';
import '../../core/theme/app_preferences_controller.dart';

/// 应用内的 Nanhu Sail 标识，实时响应偏好和当前主题。
class AppBrandIcon extends StatelessWidget {
  const AppBrandIcon({super.key, this.size = 76, this.style});

  final double size;
  final AppIconStyle? style;

  @override
  Widget build(BuildContext context) {
    final controller = AppPreferencesController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final prefs = controller.state;
        final selected = style ?? prefs.appIconStyle;
        final colors = AppIconColors.resolve(
          style: selected,
          seed: prefs.seedColor,
          isDark: theme.brightness == Brightness.dark,
        );
        return Semantics(
          image: true,
          label: '嘉兴大学应用图标 · ${selected.label}',
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(size * 0.26),
            child: CustomPaint(
              size: Size.square(size),
              painter: AppBrandIconPainter(colors),
            ),
          ),
        );
      },
    );
  }
}

/// 1024 坐标母稿：南湖帆与三层翻开的书页，保持原始贝塞尔轮廓。
class AppBrandIconPainter extends CustomPainter {
  const AppBrandIconPainter(this.colors);
  final AppIconColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024, size.height / 1024);
    const bounds = Rect.fromLTWH(0, 0, 1024, 1024);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [colors.top, colors.bottom],
        ).createShader(bounds),
    );
    final sail = Path()
      ..moveTo(408, 214)
      ..cubicTo(410, 206, 420, 203, 430, 206)
      ..cubicTo(502, 226, 578, 245, 650, 260)
      ..cubicTo(661, 262, 668, 271, 669, 282)
      ..cubicTo(684, 422, 632, 566, 422, 590)
      ..cubicTo(411, 591, 405, 582, 413, 574)
      ..cubicTo(520, 498, 518, 368, 434, 248)
      ..cubicTo(424, 234, 414, 223, 408, 214)
      ..close();
    canvas.drawPath(sail, Paint()..color = colors.sail);
    final first = Path()
      ..moveTo(244, 628)
      ..lineTo(428, 628)
      ..cubicTo(462, 628, 488, 638, 512, 652)
      ..cubicTo(536, 638, 562, 628, 596, 628)
      ..lineTo(780, 628)
      ..cubicTo(790, 628, 796, 636, 793, 645)
      ..cubicTo(790, 654, 783, 660, 773, 660)
      ..lineTo(592, 660)
      ..cubicTo(562, 660, 536, 670, 512, 684)
      ..cubicTo(488, 670, 462, 660, 432, 660)
      ..lineTo(251, 660)
      ..cubicTo(241, 660, 234, 654, 231, 645)
      ..cubicTo(228, 636, 234, 628, 244, 628)
      ..close();
    final second = Path()
      ..moveTo(276, 690)
      ..lineTo(434, 690)
      ..cubicTo(464, 690, 489, 701, 512, 716)
      ..cubicTo(535, 701, 560, 690, 590, 690)
      ..lineTo(748, 690)
      ..cubicTo(758, 690, 764, 699, 759, 708)
      ..cubicTo(754, 717, 746, 722, 736, 722)
      ..lineTo(586, 722)
      ..cubicTo(558, 722, 535, 733, 512, 748)
      ..cubicTo(489, 733, 466, 722, 438, 722)
      ..lineTo(288, 722)
      ..cubicTo(278, 722, 270, 717, 265, 708)
      ..cubicTo(260, 699, 266, 690, 276, 690)
      ..close();
    final third = Path()
      ..moveTo(326, 752)
      ..lineTo(442, 752)
      ..cubicTo(468, 752, 491, 763, 512, 778)
      ..cubicTo(533, 763, 556, 752, 582, 752)
      ..lineTo(698, 752)
      ..cubicTo(709, 752, 714, 763, 706, 772)
      ..cubicTo(658, 814, 590, 836, 512, 836)
      ..cubicTo(434, 836, 366, 814, 318, 772)
      ..cubicTo(310, 763, 315, 752, 326, 752)
      ..close();
    for (final (index, path) in [first, second, third].indexed) {
      canvas.drawPath(path, Paint()..color = colors.waves[index]);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AppBrandIconPainter oldDelegate) =>
      oldDelegate.colors.top != colors.top ||
      oldDelegate.colors.bottom != colors.bottom ||
      oldDelegate.colors.sail != colors.sail ||
      !listEquals(oldDelegate.colors.waves, colors.waves);
}
