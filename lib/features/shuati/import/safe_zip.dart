/// 带资源上限的只读 ZIP 读取（xlsx / docx / 备份 zip 共用）。
///
/// 自己解析中央目录而不是整包交给 `archive`：`archive` 的 `size` 来自头部、可以被
/// 伪造，而且解压不设上限（zip 炸弹）。这里对每个条目：
///
/// - 只按**名字**在内存里读，不写磁盘，因此没有路径穿越问题；
/// - 拒绝加密条目 / Zip64 / 非 stored+deflate 的压缩方法；
/// - 用 `dart:io` 的 raw inflate 流式解压，**累计输出一超过上限立即中止**；
/// - 解压后校验 CRC-32。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// ZIP 结构损坏 / 不受支持 / 超出资源上限。
class SafeZipException implements Exception {
  const SafeZipException(this.message, {this.limitExceeded = false});

  final String message;

  /// `true` 表示因超过大小 / 条目数上限被拒（而不是文件损坏）。
  final bool limitExceeded;

  @override
  String toString() => 'SafeZipException: $message';
}

/// 中央目录里的一个条目。
class SafeZipEntry {
  const SafeZipEntry({
    required this.name,
    required this.flags,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  final String name;
  final int flags;
  final int method;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
}

class SafeZipReader {
  SafeZipReader._(this._bytes, this.entries);

  final Uint8List _bytes;

  /// 名字 → 条目（同名取最后一个，与多数解压器一致）。
  final Map<String, SafeZipEntry> entries;

  static const int _eocdSignature = 0x06054b50;
  static const int _cdSignature = 0x02014b50;
  static const int _localSignature = 0x04034b50;

  /// 条目数上限（防御恶意中央目录）。
  static const int maxEntries = 10000;

  static bool looksLikeZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      (bytes[2] == 0x03 || bytes[2] == 0x05) &&
      (bytes[3] == 0x04 || bytes[3] == 0x06);

  static SafeZipReader open(Uint8List bytes) {
    if (bytes.length < 22) throw const SafeZipException('不是有效的 ZIP 文件');
    final data = ByteData.sublistView(bytes);

    var eocd = -1;
    final lowest = bytes.length - 22 - 0xFFFF < 0
        ? 0
        : bytes.length - 22 - 0xFFFF;
    for (var i = bytes.length - 22; i >= lowest; i--) {
      if (data.getUint32(i, Endian.little) == _eocdSignature) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const SafeZipException('找不到 ZIP 中央目录');

    final total = data.getUint16(eocd + 10, Endian.little);
    final cdSize = data.getUint32(eocd + 12, Endian.little);
    final cdOffset = data.getUint32(eocd + 16, Endian.little);
    if (total == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      throw const SafeZipException('不支持 Zip64');
    }
    if (total > maxEntries) {
      throw const SafeZipException('ZIP 条目过多', limitExceeded: true);
    }
    if (cdOffset + cdSize > bytes.length) {
      throw const SafeZipException('ZIP 中央目录越界');
    }

    final entries = <String, SafeZipEntry>{};
    var pos = cdOffset;
    for (var n = 0; n < total; n++) {
      if (pos + 46 > bytes.length ||
          data.getUint32(pos, Endian.little) != _cdSignature) {
        throw const SafeZipException('ZIP 中央目录损坏');
      }
      final flags = data.getUint16(pos + 8, Endian.little);
      final method = data.getUint16(pos + 10, Endian.little);
      final crc = data.getUint32(pos + 16, Endian.little);
      final compSize = data.getUint32(pos + 20, Endian.little);
      final uncompSize = data.getUint32(pos + 24, Endian.little);
      final nameLen = data.getUint16(pos + 28, Endian.little);
      final extraLen = data.getUint16(pos + 30, Endian.little);
      final commentLen = data.getUint16(pos + 32, Endian.little);
      final localOffset = data.getUint32(pos + 42, Endian.little);
      final nameStart = pos + 46;
      if (nameStart + nameLen + extraLen + commentLen > bytes.length) {
        throw const SafeZipException('ZIP 中央目录损坏');
      }
      final nameBytes = bytes.sublist(nameStart, nameStart + nameLen);
      final name = _decodeName(nameBytes, utf8Flag: flags & 0x800 != 0);
      entries[name] = SafeZipEntry(
        name: name,
        flags: flags,
        method: method,
        crc32: crc,
        compressedSize: compSize,
        uncompressedSize: uncompSize,
        localHeaderOffset: localOffset,
      );
      pos = nameStart + nameLen + extraLen + commentLen;
    }
    return SafeZipReader._(bytes, entries);
  }

  static String _decodeName(Uint8List raw, {required bool utf8Flag}) {
    if (utf8Flag) {
      try {
        return utf8.decode(raw);
      } on FormatException {
        // 退回逐字节映射。
      }
    }
    return String.fromCharCodes(raw);
  }

  bool contains(String name) => entries.containsKey(name);

  /// 读取并解压条目；解压后超过 [maxBytes] 立即抛 [SafeZipException]（`limitExceeded`）。
  Uint8List read(String name, {required int maxBytes}) {
    final entry = entries[name];
    if (entry == null) throw SafeZipException('ZIP 中没有 $name');
    if (entry.flags & 0x1 != 0) {
      throw const SafeZipException('不支持加密的 ZIP 条目');
    }
    if (entry.uncompressedSize > maxBytes) {
      throw const SafeZipException('ZIP 条目解压后过大', limitExceeded: true);
    }

    final data = ByteData.sublistView(_bytes);
    final off = entry.localHeaderOffset;
    if (off + 30 > _bytes.length ||
        data.getUint32(off, Endian.little) != _localSignature) {
      throw const SafeZipException('ZIP 本地文件头损坏');
    }
    final nameLen = data.getUint16(off + 26, Endian.little);
    final extraLen = data.getUint16(off + 28, Endian.little);
    final start = off + 30 + nameLen + extraLen;
    final end = start + entry.compressedSize;
    if (end > _bytes.length || start > end) {
      throw const SafeZipException('ZIP 条目数据越界');
    }

    final Uint8List out;
    switch (entry.method) {
      case 0:
        if (entry.compressedSize > maxBytes) {
          throw const SafeZipException('ZIP 条目过大', limitExceeded: true);
        }
        out = Uint8List.sublistView(_bytes, start, end);
      case 8:
        out = _inflate(_bytes, start, end, maxBytes);
      default:
        throw SafeZipException('不支持的 ZIP 压缩方法 ${entry.method}');
    }

    if (out.length != entry.uncompressedSize) {
      throw const SafeZipException('ZIP 条目长度与目录不符');
    }
    if (getCrc32(out) != entry.crc32) {
      throw const SafeZipException('ZIP 条目校验失败');
    }
    return out;
  }

  static Uint8List _inflate(Uint8List bytes, int start, int end, int maxBytes) {
    final filter = RawZLibFilter.inflateFilter(raw: true);
    final out = BytesBuilder(copy: false);
    var total = 0;

    void drain({required bool finish}) {
      while (true) {
        final chunk = filter.processed(flush: !finish, end: finish);
        if (chunk == null || chunk.isEmpty) break;
        total += chunk.length;
        if (total > maxBytes) {
          throw const SafeZipException('ZIP 条目解压后过大', limitExceeded: true);
        }
        out.add(chunk);
      }
    }

    try {
      var pos = start;
      while (pos < end) {
        final next = pos + 16384 < end ? pos + 16384 : end;
        filter.process(bytes, pos, next);
        pos = next;
        drain(finish: false);
      }
      filter.process(const <int>[], 0, 0);
      drain(finish: true);
    } on SafeZipException {
      rethrow;
    } on Exception {
      throw const SafeZipException('ZIP 条目解压失败');
    }
    return out.takeBytes();
  }
}
