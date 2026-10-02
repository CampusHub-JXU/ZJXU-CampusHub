import 'dart:io';

/// 内存文件系统替身：用 [IOOverrides] 把「前缀命中」的 `File` / `Directory`
/// 重定向到内存，其余路径原样走真实实现。
///
/// 为什么需要：widget 测试跑在 FakeAsync 区，真实文件 I/O 的 future 只有在
/// `tester.runAsync` 的真实事件循环里才会完成，于是测试只能「放行固定几毫秒真实
/// 时间 + 假时钟推进」去赌磁盘读写在预算内完成——机器一忙（`--concurrency=8`、
/// CI）就赌输，表现为偶发的「表单没出现 / 选择没恢复」。内存实现的 future 只靠
/// microtask 完成，`pump` 即可确定性放行，与机器负载无关。
///
/// 只实现 `JsonCacheStore` 用到的面：`File.exists/readAsString/writeAsString/
/// delete`、`Directory.exists/create/delete`；其它成员会 `noSuchMethod` 抛错，
/// 避免静默偏离真实语义。
class InMemoryFileIo {
  InMemoryFileIo();

  static const String _prefix = '/__in_memory_io__';
  final Map<String, String> _files = <String, String>{};
  final Set<String> _dirs = <String>{};
  int _nextRoot = 0;

  /// 当前存在的文件路径（断言 / 调试用）。
  Iterable<String> get filePaths => _files.keys;

  /// 新建一个独立根目录（等价 `Directory.systemTemp.createTempSync`）。
  /// 必须在 [install] 之后调用，否则返回的是真实目录对象。
  Directory createRoot([String name = 'root']) {
    final path = '$_prefix/${name}_${_nextRoot++}';
    _dirs.add(path);
    return Directory(path);
  }

  IOOverrides? _previous;

  /// 安装全局 [IOOverrides]；与 [uninstall] 成对（`setUp` / `tearDown`）。
  void install() {
    _previous = IOOverrides.current;
    IOOverrides.global = _Overrides(this, _previous);
  }

  void uninstall() {
    IOOverrides.global = _previous;
    _previous = null;
  }

  bool _owns(String path) => path.startsWith(_prefix);
}

final class _Overrides extends IOOverrides {
  _Overrides(this._fs, this._inner);

  final InMemoryFileIo _fs;
  final IOOverrides? _inner;

  @override
  File createFile(String path) {
    if (_fs._owns(path)) return _MemFile(_fs, path);
    return _inner?.createFile(path) ?? super.createFile(path);
  }

  @override
  Directory createDirectory(String path) {
    if (_fs._owns(path)) return _MemDirectory(_fs, path);
    return _inner?.createDirectory(path) ?? super.createDirectory(path);
  }
}

class _MemFile implements File {
  _MemFile(this._fs, this.path);

  final InMemoryFileIo _fs;

  @override
  final String path;

  @override
  Future<bool> exists() async => _fs._files.containsKey(path);

  @override
  Future<String> readAsString({dynamic encoding}) async {
    final content = _fs._files[path];
    if (content == null) {
      throw PathNotFoundException(path, const OSError('No such file', 2));
    }
    return content;
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    dynamic encoding,
    bool flush = false,
  }) async {
    _fs._files[path] = contents;
    return this;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    _fs._files.remove(path);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('InMemoryFileIo: File.${invocation.memberName}');
}

class _MemDirectory implements Directory {
  _MemDirectory(this._fs, this.path);

  final InMemoryFileIo _fs;

  @override
  final String path;

  @override
  Future<bool> exists() async => _fs._dirs.contains(path);

  @override
  Future<Directory> create({bool recursive = false}) async {
    _fs._dirs.add(path);
    return this;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    _fs._dirs.remove(path);
    _fs._files.removeWhere((key, _) => key.startsWith('$path${Platform.pathSeparator}'));
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'InMemoryFileIo: Directory.${invocation.memberName}',
  );
}
