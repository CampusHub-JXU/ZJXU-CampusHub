import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/storage/atomic_json_file.dart';

void main() {
  late Directory dir;
  late AtomicJsonFile io;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atomic_json_file_test_');
    io = AtomicJsonFile('s.json', directory: () => Future.value(dir));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Map?> readMap(File f, {void Function()? onCorrupt}) => io.read<Map?>(
    f,
    absent: null,
    decode: (raw) => raw is Map ? raw : throw const FormatException('x'),
    onCorrupt: (_, _) {
      onCorrupt?.call();
      return {'corrupt': true};
    },
  );

  test('文件不存在返回 absent；写后可读且不留临时文件', () async {
    final file = await io.file();
    expect(await readMap(file), isNull);

    await AtomicJsonFile.write(file, {'a': 1});
    expect(await readMap(file), {'a': 1});
    expect(
      dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
      ['s.json'],
    );
  });

  test('损坏内容交给 onCorrupt', () async {
    final file = await io.file();
    await file.writeAsString('not json');
    var called = false;
    expect(await readMap(file, onCorrupt: () => called = true), {
      'corrupt': true,
    });
    expect(called, isTrue);

    await file.writeAsString('[1,2]');
    expect(await readMap(file), {'corrupt': true});
  });

  test('siblingFile 与 safeDelete', () async {
    final lock = await io.siblingFile('s.lock');
    expect(lock.parent.path, dir.path);
    await lock.writeAsString('x');
    await AtomicJsonFile.safeDelete(lock);
    expect(await lock.exists(), isFalse);
    await AtomicJsonFile.safeDelete(lock); // 不存在也不抛
  });
}
