import 'dart:io';

import 'package:jnigen/jnigen.dart';

Future<void> main(List<String> args) async {
  final packageRoot = Platform.script.resolve('../');
  final generator = JniGenerator(
    input: Input(
      backend: SummarizerBackend.asm,
      classPath: [packageRoot.resolve('build/app/tmp/kotlin-classes/debug/')],
      classes: [
        'edu.zjxu.jxucampushub.platform.app_icon.AppIconChannelHandler',
        'edu.zjxu.jxucampushub.platform.download.DownloadChannelHandler',
        'edu.zjxu.jxucampushub.platform.system_settings.SystemSettingsChannelHandler',
        'edu.zjxu.jxucampushub.platform.system_settings.SystemBackgroundStatusSnapshot',
        'edu.zjxu.jxucampushub.platform.wechat.WeChatChannelHandler',
        'edu.zjxu.jxucampushub.platform.wechat.WeChatJniResult',
        'edu.zjxu.jxucampushub.platform.widget.WidgetChannelHandler',
        'edu.zjxu.jxucampushub.platform.widget.WidgetStatusJniSnapshot',
      ],
      androidSdk: AndroidSdk(addGradleDeps: true, androidExample: packageRoot),
    ),
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve(
          'lib/core/platform/android_platform_bindings.dart',
        ),
        structure: OutputStructure.singleFile,
      ),
    ),
  );
  await generator.generate();
}
