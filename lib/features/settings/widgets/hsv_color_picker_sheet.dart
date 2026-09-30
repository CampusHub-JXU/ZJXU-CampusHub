import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_feedback.dart';

Future<Color?> showHsvColorPickerSheet(
  BuildContext context, {
  required Color initialColor,
}) {
  return AppFeedback.sheet<Color>(
    context,
    scrollControlled: true,
    builder: (context) => _HsvColorPickerSheet(initialColor: initialColor),
  );
}

class _HsvColorPickerSheet extends StatefulWidget {
  const _HsvColorPickerSheet({required this.initialColor});

  final Color initialColor;

  @override
  State<_HsvColorPickerSheet> createState() => _HsvColorPickerSheetState();
}

class _HsvColorPickerSheetState extends State<_HsvColorPickerSheet> {
  late HSVColor _hsv = HSVColor.fromColor(
    widget.initialColor.withValues(alpha: 1),
  );

  Color get _selectedColor => _hsv.toColor().withValues(alpha: 1);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, bottomInset + 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '自定义主题色',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  _formatHexColor(_selectedColor),
                  style: textTheme.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _ColorPreview(color: _selectedColor),
            const SizedBox(height: 18),
            _HsvColorPlane(
              hsv: _hsv,
              onChanged: (value) => setState(() => _hsv = value),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.light_mode_outlined,
                  color: colors.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Text('亮度', style: textTheme.bodyMedium),
                const Spacer(),
                Text(
                  '${(_hsv.value * 100).round()}%',
                  style: textTheme.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            Slider.adaptive(
              min: 0,
              max: 1,
              divisions: 100,
              value: _hsv.value,
              onChanged: (value) {
                setState(() => _hsv = _hsv.withValue(value));
              },
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(_selectedColor),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorPreview extends StatelessWidget {
  const _ColorPreview({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final foreground = color.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      child: Text(
        _formatHexColor(color),
        style: TextStyle(
          color: foreground,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _HsvColorPlane extends StatelessWidget {
  const _HsvColorPlane({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);

              return GestureDetector(
                key: const ValueKey('hsv-color-plane'),
                behavior: HitTestBehavior.opaque,
                onPanDown: (details) =>
                    _updateColor(details.localPosition, size),
                onPanUpdate: (details) =>
                    _updateColor(details.localPosition, size),
                child: CustomPaint(painter: _HsvPlanePainter(hsv)),
              );
            },
          ),
        ),
      ),
    );
  }

  void _updateColor(Offset position, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final x = position.dx.clamp(0.0, size.width).toDouble();
    final y = position.dy.clamp(0.0, size.height).toDouble();
    final hue = (x / size.width * 360).clamp(0.0, 359.999).toDouble();
    final saturation = (1 - y / size.height).clamp(0.0, 1.0).toDouble();

    onChanged(hsv.withHue(hue).withSaturation(saturation));
  }
}

class _HsvPlanePainter extends CustomPainter {
  const _HsvPlanePainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(AppRadius.card);
    final rrect = RRect.fromRectAndRadius(rect, radius);

    final hueColors = List<Color>.generate(
      13,
      (index) => HSVColor.fromAHSV(1, index * 30, 1, hsv.value).toColor(),
    );
    final huePaint = Paint()
      ..shader = LinearGradient(colors: hueColors).createShader(rect);

    final gray = Color.fromARGB(
      255,
      (hsv.value * 255).round(),
      (hsv.value * 255).round(),
      (hsv.value * 255).round(),
    );
    final saturationPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, gray],
      ).createShader(rect);

    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(rect, huePaint);
    canvas.drawRect(rect, saturationPaint);
    canvas.restore();

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.22);
    canvas.drawRRect(rrect, borderPaint);

    final marker = Offset(
      (hsv.hue / 360).clamp(0.0, 1.0).toDouble() * size.width,
      (1 - hsv.saturation).clamp(0.0, 1.0).toDouble() * size.height,
    );
    final markerColor = hsv.toColor().computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    canvas.drawCircle(
      marker,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.black.withValues(alpha: 0.24),
    );
    canvas.drawCircle(
      marker,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = markerColor,
    );
  }

  @override
  bool shouldRepaint(_HsvPlanePainter oldDelegate) => oldDelegate.hsv != hsv;
}

String _formatHexColor(Color color) {
  final rgb = color.withValues(alpha: 1).toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
