import 'package:flutter/widgets.dart';

class TextScaleController {
  TextScaleController._();
  static const double minScaleFactor = 0.7;
  static const double maxScaleFactor = 1.2;

  /// 步进 0.01：85% 与 90% 之间可选 86/87/88/89% 等细档。
  static const double scaleStep = 0.01;

  /// 默认 0.9：在 MIUI 默认字号下整体收一档；**真实生效**（相对系统
  /// 缩放 ×0.9），不存在「默认值直接透传系统」的特例。
  static const double defaultScaleFactor = 0.9;

  static int get sliderDivisions =>
      ((maxScaleFactor - minScaleFactor) / scaleStep).round();

  static double normalizeScaleFactor(double? value) {
    if (value == null) return defaultScaleFactor;
    final clamped = value.clamp(minScaleFactor, maxScaleFactor);
    final steps = ((clamped - minScaleFactor) / scaleStep).round();
    final normalized = minScaleFactor + (steps * scaleStep);
    return double.parse(normalized.toStringAsFixed(2));
  }
}

class AppTextScaleScope extends StatelessWidget {
  const AppTextScaleScope({
    super.key,
    required this.scaleFactor,
    required this.child,
  });

  final double scaleFactor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // 始终相对系统 textScaler 叠乘用户因子（包括默认值 0.9）——跟随
    // MIUI/系统字体大小，再整体乘缩放；任何因子都不透传系统原始值。
    final textScaler = _RelativeTextScaler(
      base: mediaQuery.textScaler,
      factor: TextScaleController.normalizeScaleFactor(scaleFactor),
    );

    return MediaQuery(
      data: mediaQuery.copyWith(textScaler: textScaler),
      child: child,
    );
  }
}

class _RelativeTextScaler extends TextScaler {
  const _RelativeTextScaler({required this.base, required this.factor});

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) {
    return other is _RelativeTextScaler &&
        other.base == base &&
        other.factor == factor;
  }

  @override
  int get hashCode => Object.hash(base, factor);
}
