/// 文本文件字节 → 字符串，对坏编码安全。
///
/// PWA 用浏览器 `file.text()`：**只会按 UTF-8 解码**（去 BOM，坏字节变 U+FFFD）。
/// 原生保持这条主路径，并在 UTF-8 解码失败时多做两层兜底，避免国内常见的
/// Excel「另存为 CSV」（GBK）和「Unicode 文本」（UTF-16）变成乱码：
///
/// 1. UTF-16 LE/BE BOM → 按 UTF-16 解码；
/// 2. 严格 UTF-8 → 成功即用（去 BOM）；
/// 3. 失败 → 严格 GBK（`charset` 包，仓库已有依赖）；
/// 4. 仍失败 → 宽松 UTF-8（坏字节替换为 U+FFFD），并在结果里标记 [lossy]。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk;

/// 解码结果。
class DecodedText {
  const DecodedText(this.text, {this.usedGbk = false, this.lossy = false});

  final String text;

  /// 因不是合法 UTF-8 而按 GBK 解出。
  final bool usedGbk;

  /// 含无法解码的字节（已替换为 U+FFFD）。
  final bool lossy;
}

DecodedText decodeTextBytes(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return DecodedText(_utf16(bytes, 2, Endian.little));
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return DecodedText(_utf16(bytes, 2, Endian.big));
    }
  }

  final offset =
      bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF
      ? 3
      : 0;
  final body = offset == 0 ? bytes : Uint8List.sublistView(bytes, offset);

  try {
    return DecodedText(const Utf8Decoder(allowMalformed: false).convert(body));
  } on FormatException {
    // 继续兜底。
  }
  try {
    return DecodedText(gbk.decode(body), usedGbk: true);
  } on Object {
    // GBK 也失败。
  }
  return DecodedText(
    const Utf8Decoder(allowMalformed: true).convert(body),
    lossy: true,
  );
}

String _utf16(Uint8List bytes, int start, Endian endian) {
  final data = ByteData.sublistView(bytes);
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(data.getUint16(i, endian));
  }
  return String.fromCharCodes(units);
}
