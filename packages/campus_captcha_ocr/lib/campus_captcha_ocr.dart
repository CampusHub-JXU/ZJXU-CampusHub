/// Android-only, local (offline) CAPTCHA OCR platform plugin.
///
/// 原生实现位于 `android/src/main/kotlin/edu/zjxu/campus_captcha_ocr/`，方法通道
/// 为 [campusCaptchaOcrChannelName]。Dart 侧门面在应用内
/// `lib/core/captcha/captcha_recognizer.dart`，本库只暴露通道契约常量，不含
/// 业务逻辑，因此也不触网、不持有凭据。
library;

/// 插件注册的方法通道名。
const String campusCaptchaOcrChannelName = 'edu.zjxu.jxucampushub/captcha_ocr';
