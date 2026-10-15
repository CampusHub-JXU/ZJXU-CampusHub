import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const _defaultStreams = <String>['Dart', 'Embedder', 'GC'];

Future<void> main(List<String> args) async {
  late final Map<String, String> options;
  try {
    options = _parse(args);
  } catch (error) {
    stderr.writeln(error);
    _usage();
    exitCode = 2;
    return;
  }
  if (options['help'] == 'true') {
    _usage();
    return;
  }
  final serial = options['serial'];
  if (serial == null || serial.isEmpty) {
    stderr.writeln(
      'Pass --serial explicitly; device selection is never implicit.',
    );
    exitCode = 2;
    return;
  }
  final adb = options['adb'] ?? r'D:\Android\Sdk\platform-tools\adb.exe';
  final duration = int.tryParse(options['duration-seconds'] ?? '8') ?? 8;
  if (duration < 1 || duration > 60) {
    stderr.writeln('--duration-seconds must be between 1 and 60.');
    exitCode = 2;
    return;
  }
  final scenario = options['scenario'] ?? 'manual';
  final tap = options['tap'];
  final tapDelay = int.tryParse(options['tap-after-seconds'] ?? '0') ?? 0;
  final keyevent = options['keyevent'];
  final keyeventDelay =
      int.tryParse(options['keyevent-after-seconds'] ?? '0') ?? 0;
  final backgroundSeconds =
      int.tryParse(options['background-seconds'] ?? '0') ?? 0;
  final packageName = options['package'] ?? 'edu.zjxu.jxucampushub.dev';
  final activityName =
      options['activity'] ?? 'edu.zjxu.jxucampushub.MainActivity';
  final buildMode = options['build-mode'] ?? 'unknown';
  final coldStart = options['cold-start'] == 'true';
  final cpuProfileEnabled = options['cpu-profile'] == 'true';
  if (backgroundSeconds < 0 || backgroundSeconds > 60) {
    stderr.writeln('--background-seconds must be between 0 and 60.');
    exitCode = 2;
    return;
  }
  if (tapDelay < 0 ||
      keyeventDelay < 0 ||
      tapDelay >= duration ||
      keyeventDelay >= duration) {
    stderr.writeln(
      'Action delays must be non-negative and shorter than --duration-seconds.',
    );
    exitCode = 2;
    return;
  }
  if (!<String>{'debug', 'profile', 'release', 'unknown'}.contains(buildMode)) {
    stderr.writeln('--build-mode must be debug, profile, release, or unknown.');
    exitCode = 2;
    return;
  }
  final output = File(
    options['output'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}jxuc_perf_${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json',
  );

  int? forwardedPort;
  VmService? service;
  List<String>? oldStreams;
  final launchClock = Stopwatch();
  double? launchToFirstDrainMs;
  try {
    final suppliedUri = options['vm-service-uri'];
    if (coldStart && backgroundSeconds > 0) {
      throw ArgumentError(
        '--cold-start and --background-seconds cannot be combined',
      );
    }
    if (coldStart) {
      if (suppliedUri != null) {
        throw ArgumentError(
          'cold start discovers its fresh VM Service URI automatically',
        );
      }
      launchClock.start();
      await _adb(adb, serial, <String>[
        'shell',
        'am',
        'force-stop',
        packageName,
      ]);
      await _adb(adb, serial, <String>[
        'shell',
        'am',
        'start',
        '-n',
        '$packageName/$activityName',
        '--ez',
        'trace-startup',
        'true',
        '--ez',
        'enable-dart-profiling',
        'true',
      ]);
    }
    final uri = coldStart || suppliedUri == null
        ? await _discoverAndForward(
            adb,
            serial,
            packageName,
            (port) => forwardedPort = port,
          )
        : Uri.parse(suppliedUri);
    final wsUri = _webSocketUri(uri, forwardedPort);
    service = await vmServiceConnectUri(wsUri.toString());
    final vm = await service.getVM();
    final appRuntime = await _applicationIsolate(service, vm);
    final rootUri = appRuntime.$1;
    final isolateId = appRuntime.$2;
    oldStreams =
        (await service.getVMTimelineFlags()).recordedStreams ?? <String>[];

    // Preserve and drain startup events before altering timeline flags or
    // clearing the VM ring. For non-cold scenarios, select a small useful set.
    if (!coldStart) await service.setVMTimelineFlags(_defaultStreams);
    if (backgroundSeconds > 0) {
      await _adb(adb, serial, <String>[
        'shell',
        'input',
        'keyevent',
        'KEYCODE_HOME',
      ]);
      stdout.writeln(
        'App in background for $backgroundSeconds seconds; timeline is not being recorded yet.',
      );
      await Future<void>.delayed(Duration(seconds: backgroundSeconds));
    }
    final actions = <Map<String, Object?>>[];
    final scheduled = <Future<void>>[];
    final eventsByKey = <String, Map<String, dynamic>>{};
    void retain(List<TimelineEvent>? chunk) {
      for (final event in chunk ?? const <TimelineEvent>[]) {
        final json = event.toJson();
        // getVMTimeline reads the retained ring. Re-read the complete retained
        // window and deduplicate instead of clearing between RPCs: B/E spans
        // crossing RPC boundaries must stay paired and no event may be lost.
        final key = jsonEncode(<Object?>[
          json['ts'],
          json['pid'],
          json['tid'],
          json['ph'],
          json['name'],
          json['id'],
        ]);
        eventsByKey.putIfAbsent(key, () => json);
      }
    }

    final startMicros = (await service.getVMTimelineMicros()).timestamp!;
    if (coldStart) {
      final initial = await service.getVMTimeline();
      retain(initial.traceEvents);
      launchToFirstDrainMs = launchClock.elapsedMilliseconds.toDouble();
    } else {
      await service.clearVMTimeline();
    }

    if (backgroundSeconds > 0) {
      stdout.writeln(
        'Launching app; capture window starts with the launch action.',
      );
      actions.add(
        await _timedAction(
          service,
          'resume',
          () => _adb(adb, serial, <String>[
            'shell',
            'am',
            'start',
            '-n',
            '$packageName/$activityName',
          ]),
        ),
      );
    } else {
      stdout.writeln('Connected. Scenario: $scenario. Capture starts now.');
    }
    if (tap != null) {
      final parts = tap.split(',');
      if (parts.length != 2 ||
          int.tryParse(parts[0]) == null ||
          int.tryParse(parts[1]) == null) {
        throw FormatException('--tap must be X,Y');
      }
      stdout.writeln('Tap will be sent after $tapDelay seconds.');
      scheduled.add(
        _scheduleAction(
          service,
          Duration(seconds: tapDelay),
          () => _adb(adb, serial, <String>[
            'shell',
            'input',
            'tap',
            parts[0],
            parts[1],
          ]),
          actions,
          'tap',
        ),
      );
    }
    if (keyevent != null) {
      stdout.writeln(
        'Key event $keyevent will be sent after $keyeventDelay seconds.',
      );
      scheduled.add(
        _scheduleAction(
          service,
          Duration(seconds: keyeventDelay),
          () => _adb(adb, serial, <String>[
            'shell',
            'input',
            'keyevent',
            keyevent,
          ]),
          actions,
          'keyevent-$keyevent',
        ),
      );
    }
    if (tap == null && keyevent == null && backgroundSeconds == 0) {
      stdout.writeln('Perform the action now; press Enter to finish early.');
    }
    stdout.writeln('Capture stops $duration seconds after setup/launch.');
    final finished = Completer<void>();
    StreamSubscription<List<int>>? stdinSubscription;
    if (tap == null && keyevent == null) {
      try {
        stdin.lineMode = true;
        stdinSubscription = stdin.listen(
          (bytes) {
            if (!finished.isCompleted &&
                (bytes.contains(10) || bytes.contains(13))) {
              finished.complete();
            }
          },
          onError: (_) {},
          onDone: () {},
        );
      } on StdinException {
        // Pipes and IDE task runners commonly have no readable stdin. The hard
        // duration bound remains sufficient for unattended/scripted capture.
      }
    }
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < Duration(seconds: duration) &&
        !finished.isCompleted) {
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(const Duration(seconds: 1)),
        finished.future,
      ]);
      retain((await service.getVMTimeline()).traceEvents);
    }
    stopwatch.stop();
    await stdinSubscription?.cancel();
    await Future.wait(scheduled);
    retain((await service.getVMTimeline()).traceEvents);

    final endMicros = (await service.getVMTimelineMicros()).timestamp!;
    Map<String, Object?>? cpuProfile;
    if (cpuProfileEnabled) {
      try {
        final cpuSamples = await service.getCpuSamples(
          isolateId,
          coldStart ? 0 : startMicros,
          endMicros - (coldStart ? 0 : startMicros),
        );
        cpuProfile = cpuSamples.toJson();
      } catch (_) {
        cpuProfile = <String, Object?>{
          'available': false,
          'reason': 'profiler-disabled-or-unavailable',
        };
      }
    }
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': 'jxuc-vm-timeline-v1',
        'scenario': scenario,
        'duration_us': endMicros - startMicros,
        'capture_start_us': startMicros,
        'capture_end_us': endMicros,
        'background_seconds': backgroundSeconds,
        'cold_start': coldStart,
        'host_launch_to_first_drain_ms': launchToFirstDrainMs,
        'build_mode': buildMode,
        'vm_version': vm.version,
        'target_cpu': _safeString(vm.toJson()['targetCPU']),
        'root_library_kind': rootUri.contains('jxu_campus_hub')
            ? 'jxu_app'
            : 'non_test_runtime',
        'cpu_profile_requested': cpuProfileEnabled,
        'cpu_profile': cpuProfile,
        'actions': actions,
        'event_deduplication': 'timestamp-pid-tid-phase-name-id',
        'events': eventsByKey.values.toList(),
      }),
    );
    stdout.writeln(
      'Saved timeline to ${output.path} (${eventsByKey.length} retained events).',
    );
    stdout.writeln(
      'Run: python tools/perf/analyze_timeline.py "${output.path}"',
    );
  } catch (error) {
    stderr.writeln(
      'Capture failed: ${error.runtimeType}; raw service details were suppressed.',
    );
    exitCode = 1;
  } finally {
    if (service != null && oldStreams != null) {
      try {
        // Flutter Android startup tracing can leave this process's broad
        // startup recorder enabled. Cold mode owns a freshly launched process,
        // so stop Timeline recording instead of restoring startup flags.
        await service.setVMTimelineFlags(coldStart ? <String>[] : oldStreams);
      } catch (_) {
        stderr.writeln(
          coldStart
              ? 'Warning: could not disable cold-start VM Timeline recording.'
              : 'Warning: could not restore prior VM Timeline stream flags.',
        );
      }
    }
    await service?.dispose();
    if (forwardedPort != null) {
      await Process.run(adb, <String>[
        '-s',
        serial,
        'forward',
        '--remove',
        'tcp:$forwardedPort',
      ]);
    }
  }
}

Future<void> _scheduleAction(
  VmService service,
  Duration delay,
  Future<void> Function() operation,
  List<Map<String, Object?>> actions,
  String name,
) async {
  await Future<void>.delayed(delay);
  actions.add(await _timedAction(service, name, operation));
}

Future<Map<String, Object?>> _timedAction(
  VmService service,
  String name,
  Future<void> Function() operation,
) async {
  final start = (await service.getVMTimelineMicros()).timestamp!;
  await operation();
  final end = (await service.getVMTimelineMicros()).timestamp!;
  return <String, Object?>{'name': name, 'start_us': start, 'end_us': end};
}

Future<void> _adb(String adb, String serial, List<String> args) async {
  final result = await _runBounded(adb, <String>['-s', serial, ...args]);
  if (result.exitCode != 0) {
    throw StateError('adb action failed: ${args.take(3).join(' ')}');
  }
}

Future<ProcessResult> _runBounded(
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final process = await Process.start(executable, args);
  final stdoutText = process.stdout.transform(utf8.decoder).join();
  final stderrText = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(timeout);
    return ProcessResult(process.pid, code, await stdoutText, await stderrText);
  } on TimeoutException {
    process.kill();
    throw StateError('adb command timed out');
  }
}

Map<String, String> _parse(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') {
      result['help'] = 'true';
    } else if (arg == '--cold-start' || arg == '--cpu-profile') {
      result[arg.substring(2)] = 'true';
    } else if (arg.startsWith('--') && i + 1 < args.length) {
      result[arg.substring(2)] = args[++i];
    } else {
      throw FormatException('Unexpected argument: $arg');
    }
  }
  return result;
}

Future<Uri> _discoverAndForward(
  String adb,
  String serial,
  String packageName,
  void Function(int) onForward,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  RegExpMatch? match;
  while (DateTime.now().isBefore(deadline) && match == null) {
    final pidResult = await _runBounded(adb, <String>[
      '-s',
      serial,
      'shell',
      'pidof',
      packageName,
    ], timeout: const Duration(seconds: 2));
    final pidText = pidResult.stdout.toString().trim();
    if (pidResult.exitCode == 0 && pidText.isNotEmpty) {
      final pid = pidText.split(RegExp(r'\s+')).first;
      final result = await _runBounded(adb, <String>[
        '-s',
        serial,
        'logcat',
        '-d',
        '--pid=$pid',
        '-t',
        '2000',
        '-v',
        'brief',
        '-s',
        'flutter',
      ], timeout: const Duration(seconds: 2));
      if (result.exitCode == 0) {
        final matches = RegExp(
          r'Dart VM service is listening on (https?://127\.0\.0\.1:(\d+)/[^\s]+)',
        ).allMatches(result.stdout.toString());
        if (matches.isNotEmpty) match = matches.last;
      }
    }
    if (match == null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  if (match == null) {
    throw StateError(
      'VM Service URI not found; start flutter attach or pass --vm-service-uri',
    );
  }
  final remote = int.parse(match.group(2)!);
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final local = socket.port;
  await socket.close();
  final forward = await _runBounded(adb, <String>[
    '-s',
    serial,
    'forward',
    'tcp:$local',
    'tcp:$remote',
  ]);
  if (forward.exitCode != 0) throw StateError('adb forward failed');
  onForward(local);
  return Uri.parse(match.group(1)!);
}

Uri _webSocketUri(Uri uri, int? forwardedPort) {
  final path = uri.path.endsWith('/') ? '${uri.path}ws' : '${uri.path}/ws';
  return uri.replace(
    scheme: 'ws',
    host: forwardedPort == null ? uri.host : '127.0.0.1',
    port: forwardedPort ?? uri.port,
    path: path,
  );
}

Future<(String, String)> _applicationIsolate(VmService service, VM vm) async {
  for (final isolateRef in vm.isolates ?? const <IsolateRef>[]) {
    if (isolateRef.id == null) continue;
    final isolate = await service.getIsolate(isolateRef.id!);
    final rootUri = isolate.rootLib?.uri ?? '';
    if (rootUri.contains('flutter_test_listener') ||
        rootUri.contains('/flutter_test/') ||
        rootUri.contains('test.dart')) {
      throw StateError('Flutter test isolate refused');
    }
    if (rootUri.isNotEmpty) return (rootUri, isolateRef.id!);
  }
  throw StateError('VM has no application root library');
}

String? _safeString(Object? value) {
  if (value is! String) return null;
  return value.length > 80 ? value.substring(0, 80) : value;
}

void _usage() {
  stdout.writeln('''
Usage: dart run tools/perf/capture_timeline.dart --serial SERIAL [options]
  --scenario NAME             Required label for this run (e.g. resume-5s)
  --duration-seconds N        Maximum 1..60 seconds (default 8)
  --output PATH               Raw trace path (default private system temp directory)
  --adb PATH                  adb executable (default D:\\Android\\Sdk\\platform-tools\\adb.exe)
  --vm-service-uri URI        Explicit HTTP(S) VM Service discovery URI; bypasses logcat lookup
  --tap X,Y                   Send one adb shell input tap during capture
  --tap-after-seconds N       Delay scripted tap (default 0)
  --keyevent KEY              Send an Android key event during capture (e.g. KEYCODE_BACK)
  --keyevent-after-seconds N  Delay key event (default 0)
  --background-seconds N      Send HOME, wait 1..60 seconds, then launch before capture window
  --package NAME              Resume target package (default edu.zjxu.jxucampushub.dev)
  --activity NAME             Resume activity (default edu.zjxu.jxucampushub.MainActivity)
  --build-mode MODE           Operator asserted (debug/profile/release); default unknown
  --cold-start                Force-stop without clearing data, launch with Flutter startup tracing flags
  --cpu-profile               Include VM CPU profile samples when profiling is enabled
''');
}
