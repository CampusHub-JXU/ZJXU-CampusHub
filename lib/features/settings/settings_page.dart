import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/text_scale_controller.dart';
import '../../app/theme_mode_controller.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/update/update_checker.dart';
import '../../core/update/update_model.dart';
import '../../shared/widgets/update_dialog.dart';
import '../home/home_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  String _formatScaleFactor(double value) => '${(value * 100).round()}%';

  String _formatLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.debug => 'Debug',
      LogLevel.info => 'Info',
      LogLevel.warn => 'Warn',
      LogLevel.error => 'Error',
    };
  }

  String _formatDate(DateTime date) {
    final y = date.year.toString();
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _pickSemesterStartDate(
    BuildContext context,
    DateTime currentDate,
  ) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      helpText: '选择开学日',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    await SemesterCalendar.instance.setSemesterStartDate(picked);
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
      }

      final dotIdx = picked.path.lastIndexOf('.');
      final ext = dotIdx == -1 ? '.jpg' : picked.path.substring(dotIdx);
      final destPath = '${destDir.path}/bg$ext';

      final oldPath = HomeController.instance.backgroundImagePath.value;
      await File(picked.path).copy(destPath);
      await HomeController.instance.setBackgroundImagePath(destPath);

      if (oldPath != null && oldPath != destPath) {
        unawaited(File(oldPath).delete().catchError((_) => File(oldPath)));
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已设置首页背景')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选择图片失败，请稍后重试')),
        );
      }
    }
  }

  Widget _buildPersonalizationCard(
    BuildContext context, {
    required TextTheme textTheme,
    required String? bgPath,
    required bool filterEnabled,
    required HomeFilterMode filterMode,
    required List<Color> customColors,
    required bool glassEnabled,
  }) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Text('首页个性化', style: textTheme.titleSmall),
          ),
          ListTile(
            leading: const Icon(Icons.wallpaper_outlined),
            title: const Text('首页背景图片'),
            subtitle: Text(
              bgPath != null ? '已设置自定义背景' : '未设置，使用默认背景',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickHomeBackgroundImage(context),
          ),
          if (bgPath != null) ...[
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('移除背景图片'),
              onTap: () {
                HomeController.instance.clearBackgroundImage();
                HomeController.instance.setColorFilterEnabled(false);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已移除首页背景')),
                  );
                }
              },
            ),
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.color_lens_outlined),
              title: const Text('背景色彩滤镜'),
              subtitle: const Text('在背景图上叠加色彩风格滤镜'),
              value: filterEnabled,
              onChanged:
                  HomeController.instance.setColorFilterEnabled,
            ),
            if (filterEnabled) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text('滤镜模式', style: textTheme.bodySmall),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SegmentedButton<HomeFilterMode>(
                  segments: const [
                    ButtonSegment(
                      value: HomeFilterMode.brand,
                      icon: Icon(Icons.palette_outlined, size: 18),
                      label: Text('红黑白'),
                    ),
                    ButtonSegment(
                      value: HomeFilterMode.monet,
                      icon: Icon(Icons.auto_awesome_outlined, size: 18),
                      label: Text('莫奈取色'),
                    ),
                    ButtonSegment(
                      value: HomeFilterMode.custom,
                      icon: Icon(Icons.tune_outlined, size: 18),
                      label: Text('自定义'),
                    ),
                  ],
                  selected: {filterMode},
                  onSelectionChanged: (selection) {
                    HomeController.instance.setFilterMode(selection.first);
                  },
                ),
              ),
              if (filterMode == HomeFilterMode.custom)
                _buildCustomColorRow(context, customColors),
            ],
          ],
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.blur_on_outlined),
            title: const Text('首页卡片毛玻璃'),
            subtitle: const Text('对课表下方卡片区域添加模糊效果'),
            value: glassEnabled,
            onChanged: HomeController.instance.setFrostedGlassEnabled,
          ),
        ],
      ),
    );
  }

  Widget _buildCustomColorRow(BuildContext context, List<Color> colors) {
    final labels = ['主色', '副色', '底色'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _pickCustomColor(context, i, colors),
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors[i],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12,
                      color: colors[i].computeLuminance() > 0.5
                          ? Colors.black87
                          : Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
            if (i < 2) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Future<void> _pickCustomColor(
    BuildContext context,
    int index,
    List<Color> currentColors,
  ) async {
    final colors = List<Color>.from(currentColors);
    final label = ['主色', '副色', '底色'][index];
    final result = await showDialog<Color>(
      context: context,
      builder: (ctx) => _ColorPickerDialog(
        initialColor: colors[index],
        label: label,
      ),
    );
    if (result == null) return;
    colors[index] = result;
    await HomeController.instance.setCustomFilterColors(colors);
  }

  Future<void> _checkForUpdate(BuildContext context) async {
    final result = await UpdateChecker.instance.check();
    if (!context.mounted) return;

    switch (result.status) {
      case UpdateCheckStatus.disabled:
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('当前为内部开发版本，请通过统一发布渠道获取新版本')),
        );
        break;
      case UpdateCheckStatus.updateAvailable:
        final release = result.release;
        if (release != null) {
          await showUpdateDialog(context, release);
        }
        break;
      case UpdateCheckStatus.upToDate:
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
        break;
      case UpdateCheckStatus.error:
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('检查更新失败，请稍后重试')));
        break;
      case UpdateCheckStatus.checking:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('外观', style: textTheme.titleMedium),
          const SizedBox(height: 12),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeModeController.instance.themeMode,
            builder: (context, themeMode, child) {
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
                      child: Text('主题模式', style: textTheme.titleSmall),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.system,
                            icon: Icon(Icons.brightness_auto),
                            label: Text(
                              '跟随系统',
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode),
                            label: Text('浅色'),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode),
                            label: Text('深色'),
                          ),
                        ],
                        selected: {themeMode},
                        onSelectionChanged: (selection) {
                          ThemeModeController.instance.setThemeMode(
                            selection.first,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<double>(
            valueListenable: TextScaleController.instance.textScaleFactor,
            builder: (context, textScaleFactor, child) {
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      title: const Text('应用字号'),
                      subtitle: const Text('基于系统字号缩放，最大限制到 120%'),
                      trailing: Text(_formatScaleFactor(textScaleFactor)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Column(
                        children: [
                          Slider.adaptive(
                            min: TextScaleController.minScaleFactor,
                            max: TextScaleController.maxScaleFactor,
                            divisions: TextScaleController.sliderDivisions,
                            label: _formatScaleFactor(textScaleFactor),
                            value: textScaleFactor,
                            onChanged: (value) {
                              TextScaleController.instance.setTextScaleFactor(
                                value,
                              );
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '紧凑 ${_formatScaleFactor(TextScaleController.minScaleFactor)}',
                                  style: textTheme.bodySmall,
                                ),
                                Text(
                                  '上限 ${_formatScaleFactor(TextScaleController.maxScaleFactor)}',
                                  style: textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: TextButton(
                          onPressed: () {
                            TextScaleController.instance.setTextScaleFactor(
                              TextScaleController.defaultScaleFactor,
                            );
                          },
                          child: const Text('恢复默认'),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<String?>(
            valueListenable: HomeController.instance.backgroundImagePath,
            builder: (context, bgPath, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: HomeController.instance.colorFilterEnabled,
                builder: (context, filterEnabled, _) {
                  return ValueListenableBuilder<HomeFilterMode>(
                    valueListenable: HomeController.instance.filterMode,
                    builder: (context, filterMode, _) {
                      return ValueListenableBuilder<List<Color>>(
                        valueListenable:
                            HomeController.instance.customFilterColors,
                        builder: (context, customColors, _) {
                          return ValueListenableBuilder<bool>(
                            valueListenable:
                                HomeController.instance.frostedGlassEnabled,
                            builder: (context, glassEnabled, _) {
                              return _buildPersonalizationCard(
                                context,
                                textTheme: textTheme,
                                bgPath: bgPath,
                                filterEnabled: filterEnabled,
                                filterMode: filterMode,
                                customColors: customColors,
                                glassEnabled: glassEnabled,
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 16),
          Text('学期', style: textTheme.titleMedium),
          const SizedBox(height: 12),
          ValueListenableBuilder<DateTime>(
            valueListenable: SemesterCalendar.instance.semesterStartDate,
            builder: (context, semesterStartDate, child) {
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('当前学期开学日'),
                      subtitle: Text(
                        '${_formatDate(semesterStartDate)}（用于周次与下一节课计算）',
                      ),
                      trailing: const Icon(Icons.edit_calendar_outlined),
                      onTap: () async {
                        await _pickSemesterStartDate(
                          context,
                          semesterStartDate,
                        );
                      },
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: TextButton(
                          onPressed: () async {
                            await SemesterCalendar.instance
                                .resetSemesterStartDate();
                          },
                          child: const Text('恢复默认（3月2日）'),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text('设置会立即生效。', style: textTheme.bodySmall),
          const SizedBox(height: 24),
          Text('版本', style: textTheme.titleMedium),
          const SizedBox(height: 12),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final version = snapshot.hasData
                  ? '当前版本 v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                  : '查看当前版本信息';
              return ValueListenableBuilder<AppRelease?>(
                valueListenable: UpdateChecker.instance.availableRelease,
                builder: (context, release, child) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: UpdateChecker.instance.isChecking,
                    builder: (context, isChecking, child) {
                      final subtitle = release != null
                          ? '发现新版本 v${release.version}'
                          : UpdateChecker.instance.isUpdateEnabled
                          ? version
                          : '当前版本暂未开放在线更新';
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: const Icon(Icons.system_update_outlined),
                          title: const Text('检查更新'),
                          subtitle: Text(subtitle),
                          trailing: isChecking
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  release != null
                                      ? Icons.new_releases_outlined
                                      : Icons.chevron_right,
                                ),
                          onTap: isChecking
                              ? null
                              : () {
                                  _checkForUpdate(context);
                                },
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 24),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final version = snapshot.hasData
                  ? 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                  : '';
              return Center(
                child: Text(
                  '嘉兴大学-智能中台 $version',
                  style: textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            },
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            Text('调试', style: textTheme.titleMedium),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: AppLogger.instance.loggingEnabled,
              builder: (context, loggingEnabled, child) {
                return ValueListenableBuilder<LogConfig>(
                  valueListenable: AppLogger.instance.config,
                  builder: (context, logConfig, _) {
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SwitchListTile.adaptive(
                            title: const Text('调试日志'),
                            subtitle: const Text('开启后记录调试期日志和异常'),
                            value: loggingEnabled,
                            onChanged: (value) {
                              AppLogger.instance.setEnabled(value);
                            },
                          ),
                          ListTile(
                            title: const Text('最低日志级别'),
                            subtitle: Text(
                              _formatLogLevel(logConfig.minimumLevel),
                            ),
                            trailing: DropdownButton<LogLevel>(
                              value: logConfig.minimumLevel,
                              onChanged: (value) {
                                if (value == null) return;
                                AppLogger.instance.updateConfig(
                                  logConfig.copyWith(minimumLevel: value),
                                );
                              },
                              items: LogLevel.values
                                  .map(
                                    (level) => DropdownMenuItem<LogLevel>(
                                      value: level,
                                      child: Text(_formatLogLevel(level)),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                          SwitchListTile.adaptive(
                            title: const Text('WebView 生命周期日志'),
                            subtitle: const Text('页面加载、跳转和白屏探测细节'),
                            value: logConfig.webviewLifecycleEnabled,
                            onChanged: (value) {
                              AppLogger.instance.updateConfig(
                                logConfig.copyWith(
                                  webviewLifecycleEnabled: value,
                                ),
                              );
                            },
                          ),
                          SwitchListTile.adaptive(
                            title: const Text('WebView 控制台日志'),
                            subtitle: const Text('记录页面 console warning/error'),
                            value: logConfig.webviewConsoleEnabled,
                            onChanged: (value) {
                              AppLogger.instance.updateConfig(
                                logConfig.copyWith(
                                  webviewConsoleEnabled: value,
                                ),
                              );
                            },
                          ),
                          SwitchListTile.adaptive(
                            title: const Text('网络详细日志'),
                            subtitle: const Text('记录请求和响应细节，噪音较大'),
                            value: logConfig.networkVerboseEnabled,
                            onChanged: (value) {
                              AppLogger.instance.updateConfig(
                                logConfig.copyWith(
                                  networkVerboseEnabled: value,
                                ),
                              );
                            },
                          ),
                          const Divider(height: 1),
                          ListTile(
                            title: const Text('通知测试'),
                            subtitle: const Text('发送一条本地测试通知'),
                            trailing: const Icon(Icons.send_outlined),
                            onTap: () {
                              AppNotificationService.instance.showNotification(
                                id: 999,
                                title: '测试通知',
                                body: '这是一条来自开发模式的测试通知，${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
                                payload: 'test',
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initialColor, required this.label});
  final Color initialColor;
  final String label;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late double _hue;
  late double _saturation;
  late double _value;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initialColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
  }

  Color get _color => HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  static const _presets = [
    Color(0xFF8B1A2D), Color(0xFF1A8B6B), Color(0xFF1A3B8B),
    Color(0xFF8B6B1A), Color(0xFF5A1A8B), Color(0xFF1A8B8B),
    Colors.black, Colors.white, Color(0xFF666666),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('选择${widget.label}'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildSlider('色相', _hue, 0, 360, (v) => setState(() => _hue = v),
                gradient: LinearGradient(
                  colors: [for (var i = 0; i <= 360; i += 30)
                    HSVColor.fromAHSV(1, i.toDouble(), 1, 1).toColor()],
                )),
            _buildSlider('饱和', _saturation, 0, 1, (v) => setState(() => _saturation = v),
                activeColor: HSVColor.fromAHSV(1, _hue, 1, _value).toColor()),
            _buildSlider('明度', _value, 0, 1, (v) => setState(() => _value = v),
                activeColor: HSVColor.fromAHSV(1, _hue, _saturation, 1).toColor()),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presets.map((c) {
                final selected = c.toARGB32() == _color.toARGB32();
                return GestureDetector(
                  onTap: () {
                    final hsv = HSVColor.fromColor(c);
                    setState(() {
                      _hue = hsv.hue;
                      _saturation = hsv.saturation;
                      _value = hsv.value;
                    });
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.withValues(alpha: 0.3),
                        width: selected ? 2.5 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    Gradient? gradient,
    Color? activeColor,
  }) {
    return Row(
      children: [
        SizedBox(width: 36, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: gradient != null
              ? ShaderMask(
                  shaderCallback: (bounds) => gradient.createShader(bounds),
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    onChanged: onChanged,
                    activeColor: Colors.white,
                    inactiveColor: Colors.grey.withValues(alpha: 0.3),
                  ),
                )
              : Slider(
                  value: value,
                  min: min,
                  max: max,
                  activeColor: activeColor,
                  onChanged: onChanged,
                ),
        ),
      ],
    );
  }
}
