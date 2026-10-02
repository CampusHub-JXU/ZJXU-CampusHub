import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// 磨砂玻璃的细颗粒层。
///
/// 一块 64×64 灰度 + alpha 的噪点 PNG，进程内只生成一次（确定性种子，同步、
/// 不落盘），经 [DecorationImage] 平铺到表面装饰上——随装饰一起被 squircle /
/// 圆角裁剪，不需要额外 widget 层，也不逐帧生成随机点。
///
/// 颗粒只铺在表面填充之上、内容之下，强度很低（见 [frostGrainImage]）。
const int _kTile = 64;

Uint8List? _tilePng;
DecorationImage? _lightGrain;
DecorationImage? _darkGrain;

/// 磨砂颗粒装饰图。浅 / 深色各取一档强度，实例全局复用。
DecorationImage frostGrainImage({required bool isDark}) {
  _tilePng ??= _buildNoisePng();
  if (isDark) {
    return _darkGrain ??= DecorationImage(
      image: MemoryImage(_tilePng!),
      repeat: ImageRepeat.repeat,
      // 1 个噪点 ≈ 1 物理像素（常见 3x 屏），保持「细」。
      scale: 3.0,
      opacity: 0.55,
      filterQuality: FilterQuality.none,
    );
  }
  return _lightGrain ??= DecorationImage(
    image: MemoryImage(_tilePng!),
    repeat: ImageRepeat.repeat,
    scale: 3.0,
    opacity: 0.40,
    filterQuality: FilterQuality.none,
  );
}

Uint8List _buildNoisePng() {
  // 线性同余，固定种子：每次启动颗粒图案一致，测试可复现。
  var seed = 0x2F6E2B1;
  int next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed >> 8;
  }

  final raw = BytesBuilder();
  for (var y = 0; y < _kTile; y++) {
    raw.addByte(0); // filter: None
    for (var x = 0; x < _kTile; x++) {
      final r = next();
      raw.addByte((r & 1) == 0 ? 255 : 0); // 灰度：亮 / 暗点各半
      raw.addByte((r >> 1) % 34); // alpha 0..33，整体很淡
    }
  }

  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, _kTile)
    ..setUint32(4, _kTile)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 4); // color type: grayscale + alpha
  _chunk(out, 'IHDR', ihdr.buffer.asUint8List());
  _chunk(out, 'IDAT', Uint8List.fromList(ZLibCodec().encode(raw.toBytes())));
  _chunk(out, 'IEND', Uint8List(0));
  return out.toBytes();
}

void _chunk(BytesBuilder out, String type, Uint8List data) {
  final typeBytes = type.codeUnits;
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  out.add(typeBytes);
  out.add(data);
  final crc = ByteData(4)
    ..setUint32(0, _crc32([...typeBytes, ...data]));
  out.add(crc.buffer.asUint8List());
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
