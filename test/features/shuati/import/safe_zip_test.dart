// SafeZipReader：带资源上限的只读 ZIP（防 zip 炸弹 / 伪造头 / 损坏）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/import/safe_zip.dart';

import '../../../helpers/shuati_office_fixtures.dart';

Uint8List _patchCentral(
  Uint8List zip, {
  int? crc,
  int? uncompressed,
  int? flags,
}) {
  final out = Uint8List.fromList(zip);
  final data = ByteData.sublistView(out);
  for (var i = 0; i < out.length - 4; i++) {
    if (data.getUint32(i, Endian.little) == 0x02014b50) {
      if (flags != null) {
        data.setUint16(i + 8, flags, Endian.little);
      }
      if (crc != null) {
        data.setUint32(i + 16, crc, Endian.little);
      }
      if (uncompressed != null) {
        data.setUint32(i + 24, uncompressed, Endian.little);
      }
    }
  }
  return out;
}

void main() {
  group('SafeZipReader', () {
    test('读取 stored / deflate 条目', () {
      final bytes = zipBytes({
        'a.txt': utf8.encode('hello world ' * 100),
        'dir/b.txt': utf8.encode('b'),
      });
      final zip = SafeZipReader.open(bytes);
      expect(zip.contains('a.txt'), isTrue);
      expect(
        utf8.decode(zip.read('a.txt', maxBytes: 1 << 20)),
        'hello world ' * 100,
      );
      expect(utf8.decode(zip.read('dir/b.txt', maxBytes: 1 << 20)), 'b');
      expect(zip.contains('missing'), isFalse);
    });

    test('looksLikeZip：魔数', () {
      expect(
        SafeZipReader.looksLikeZip(
          zipBytes({
            'a': [1],
          }),
        ),
        isTrue,
      );
      expect(
        SafeZipReader.looksLikeZip(
          Uint8List.fromList(utf8.encode('{"version":3}')),
        ),
        isFalse,
      );
      expect(SafeZipReader.looksLikeZip(Uint8List(2)), isFalse);
    });

    test('解压后超过 maxBytes：立即中止（声明大小如实）', () {
      final bytes = zipBytes({'big.bin': Uint8List(5 * 1024 * 1024)}, level: 9);
      final zip = SafeZipReader.open(bytes);
      expect(
        () => zip.read('big.bin', maxBytes: 1024 * 1024),
        throwsA(
          isA<SafeZipException>().having(
            (e) => e.limitExceeded,
            'limitExceeded',
            isTrue,
          ),
        ),
      );
    });

    test('头部伪造小的 uncompressedSize：流式解压到上限即中止（不信任头）', () {
      final bytes = zipBytes({'big.bin': Uint8List(5 * 1024 * 1024)}, level: 9);
      final lying = _patchCentral(bytes, uncompressed: 100);
      final zip = SafeZipReader.open(lying);
      expect(
        () => zip.read('big.bin', maxBytes: 1024 * 1024),
        throwsA(
          isA<SafeZipException>().having(
            (e) => e.limitExceeded,
            'limitExceeded',
            isTrue,
          ),
        ),
      );
      // 上限足够大时，长度与目录不符也被拒
      expect(
        () =>
            SafeZipReader.open(lying)
                .read('big.bin', maxBytes: 64 * 1024 * 1024),
        throwsA(isA<SafeZipException>()),
      );
    });

    test('CRC 不匹配 → 校验失败', () {
      final bytes = zipBytes({'a.txt': utf8.encode('payload payload payload')});
      final bad = _patchCentral(bytes, crc: 0xDEADBEEF);
      expect(
        () => SafeZipReader.open(bad).read('a.txt', maxBytes: 1024),
        throwsA(isA<SafeZipException>()),
      );
    });

    test('加密条目被拒', () {
      final bytes = zipBytes({'a.txt': utf8.encode('x')});
      final enc = _patchCentral(bytes, flags: 0x1);
      expect(
        () => SafeZipReader.open(enc).read('a.txt', maxBytes: 1024),
        throwsA(isA<SafeZipException>()),
      );
    });

    test('截断 / 垃圾 / 空输入 → SafeZipException', () {
      final bytes = zipBytes({'a.txt': utf8.encode('x' * 1000)});
      expect(
        () => SafeZipReader.open(bytes.sublist(0, bytes.length - 10)),
        throwsA(isA<SafeZipException>()),
      );
      expect(
        () => SafeZipReader.open(Uint8List.fromList(List.filled(100, 7))),
        throwsA(isA<SafeZipException>()),
      );
      expect(
        () => SafeZipReader.open(Uint8List(0)),
        throwsA(isA<SafeZipException>()),
      );
    });

    test('损坏的 deflate 流 → SafeZipException（不是未捕获异常）', () {
      final bytes = zipBytes({'a.txt': utf8.encode('abc' * 1000)});
      final data = ByteData.sublistView(bytes);
      // 本地头后紧跟压缩数据：翻转其中若干字节
      final nameLen = data.getUint16(26, Endian.little);
      final extraLen = data.getUint16(28, Endian.little);
      final start = 30 + nameLen + extraLen;
      final broken = Uint8List.fromList(bytes);
      for (var i = start; i < start + 8; i++) {
        broken[i] = 0xFF;
      }
      expect(
        () => SafeZipReader.open(broken).read('a.txt', maxBytes: 1 << 20),
        throwsA(isA<SafeZipException>()),
      );
    });

    test('条目名只在内存查找，.. 等路径不会触及磁盘', () {
      final bytes = zipBytes({
        '../evil.txt': utf8.encode('x'),
        '/abs.txt': utf8.encode('y'),
      });
      final zip = SafeZipReader.open(bytes);
      expect(zip.contains('../evil.txt'), isTrue);
      expect(utf8.decode(zip.read('../evil.txt', maxBytes: 10)), 'x');
    });

    test('archive 编码器产出的 zip 与本读取器互通（备份导出用）', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes('backup.json', utf8.encode('{"version":3}')),
        );
      final zip = SafeZipReader.open(
        ZipEncoder().encodeBytes(archive, level: 9),
      );
      expect(
        utf8.decode(zip.read('backup.json', maxBytes: 1024)),
        '{"version":3}',
      );
    });
  });
}
