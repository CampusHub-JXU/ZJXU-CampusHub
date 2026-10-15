import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

/// 最小 PNG 解析 + 贴图统计，供 Issue #47 的闪粉贴图测试使用。
///
/// 只支持 8 位、非隔行的灰度 / 灰度+alpha / RGB / RGBA（本仓库的贴图就是灰度+alpha）。
/// 解出来的像素统一成每像素 4 字节（R,G,B,A），方便断言「白色峰值 + 稀疏 alpha」。
class TextureProbe {
  TextureProbe._(this.width, this.height, this.colorType, this.pixels);

  final int width;
  final int height;
  final int colorType;

  /// 每像素 4 字节：R, G, B, A。
  final Uint8List pixels;

  int get pixelCount => width * height;

  int alphaAt(int x, int y) => pixels[(y * width + x) * 4 + 3];

  int redAt(int x, int y) => pixels[(y * width + x) * 4];

  /// alpha > 0 的像素占比（「有峰值」的覆盖比例）。
  double coverage() => _fraction((a) => a > 0);

  /// alpha >= 128 的像素占比（明显可见的亮峰值）。
  double brightFraction() => _fraction((a) => a >= 128);

  double meanAlpha() {
    var sum = 0;
    for (var i = 0; i < pixelCount; i++) {
      sum += pixels[i * 4 + 3];
    }
    return sum / pixelCount;
  }

  int maxAlpha() {
    var max = 0;
    for (var i = 0; i < pixelCount; i++) {
      final a = pixels[i * 4 + 3];
      if (a > max) max = a;
    }
    return max;
  }

  /// 所有像素的 RGB 是否都等于 [value]（用于断言「白色峰值」）。
  bool allPixelsHaveRgb(int value) {
    for (var i = 0; i < pixelCount; i++) {
      final o = i * 4;
      if (pixels[o] != value ||
          pixels[o + 1] != value ||
          pixels[o + 2] != value) {
        return false;
      }
    }
    return true;
  }

  /// alpha > 0 的水平平均游程（像素）；值越大越「成片」，1 表示逐像素噪声。
  double meanHorizontalRun() {
    var runs = 0;
    var total = 0;
    for (var y = 0; y < height; y++) {
      var run = 0;
      for (var x = 0; x < width; x++) {
        if (alphaAt(x, y) > 0) {
          run++;
        } else if (run > 0) {
          runs++;
          total += run;
          run = 0;
        }
      }
      if (run > 0) {
        runs++;
        total += run;
      }
    }
    return runs == 0 ? 0 : total / runs;
  }

  /// alpha > 0 的水平最长游程（像素）；用来拒绝「成片大团块」（旧贴图 8 逻辑 dp 级的灰尘感）。
  int maxHorizontalRun() {
    var best = 0;
    for (var y = 0; y < height; y++) {
      var run = 0;
      for (var x = 0; x < width; x++) {
        if (alphaAt(x, y) > 0) {
          run++;
          if (run > best) best = run;
        } else {
          run = 0;
        }
      }
    }
    return best;
  }

  /// 跨 tile 接缝（最后一列↔第一列、最后一行↔第一行）上「有峰值」像素对的重叠率
  /// （交并比：两侧都 > 0 的对数 / 任一侧 > 0 的对数）。
  ///
  /// 稀疏贴图上「接缝差 <= 内部差」区分不出无缝与否（独立的两列也会得到相近的小差值），
  /// 重叠率可以：真正环绕连续时与内部相邻像素同量级，两列独立时只有约 0.04。
  double seamOverlap() {
    var both = 0;
    var either = 0;
    void count(int a, int b) {
      if (a > 0 && b > 0) both++;
      if (a > 0 || b > 0) either++;
    }

    for (var y = 0; y < height; y++) {
      count(alphaAt(width - 1, y), alphaAt(0, y));
    }
    for (var x = 0; x < width; x++) {
      count(alphaAt(x, height - 1), alphaAt(x, 0));
    }
    return either == 0 ? 0 : both / either;
  }

  /// tile 内部相邻像素（水平 + 垂直）的同一重叠率，作为 [seamOverlap] 的参照。
  double interiorOverlap() {
    var both = 0;
    var either = 0;
    void count(int a, int b) {
      if (a > 0 && b > 0) both++;
      if (a > 0 || b > 0) either++;
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width - 1; x++) {
        count(alphaAt(x, y), alphaAt(x + 1, y));
      }
    }
    for (var y = 0; y < height - 1; y++) {
      for (var x = 0; x < width; x++) {
        count(alphaAt(x, y), alphaAt(x, y + 1));
      }
    }
    return either == 0 ? 0 : both / either;
  }

  /// 平铺接缝：|最后一列 - 第一列| 的平均值（跨 tile 边界）。
  double edgeSeamDelta() {
    var sum = 0;
    for (var y = 0; y < height; y++) {
      sum += (alphaAt(width - 1, y) - alphaAt(0, y)).abs();
    }
    return sum / height;
  }

  /// tile 内部相邻列的平均差；接缝应 <= 内部差才说明无缝。
  double interiorNeighbourDelta() {
    var sum = 0;
    var n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width - 1; x++) {
        sum += (alphaAt(x + 1, y) - alphaAt(x, y)).abs();
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  /// 两张同尺寸贴图的 alpha 差异（占比 > [threshold] 的像素比例）。
  double alphaDifferenceFraction(TextureProbe other, int threshold) {
    var n = 0;
    for (var i = 0; i < pixelCount; i++) {
      if ((pixels[i * 4 + 3] - other.pixels[i * 4 + 3]).abs() > threshold) {
        n++;
      }
    }
    return n / pixelCount;
  }

  double _fraction(bool Function(int alpha) test) {
    var n = 0;
    for (var i = 0; i < pixelCount; i++) {
      if (test(pixels[i * 4 + 3])) n++;
    }
    return n / pixelCount;
  }
}

/// 解析 PNG 字节（8 位、非隔行）。
TextureProbe decodeTexture(Uint8List bytes) {
  const signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 8) {
    throw StateError('not a PNG (too short)');
  }
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) {
      throw StateError('bad PNG signature');
    }
  }

  var offset = 8;
  var width = 0;
  var height = 0;
  var bitDepth = 0;
  var colorType = 0;
  var interlace = 0;
  final idat = BytesBuilder();
  while (offset + 8 <= bytes.length) {
    final length = _readUint32(bytes, offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    final dataStart = offset + 8;
    if (dataStart + length > bytes.length) {
      throw StateError('truncated chunk $type');
    }
    if (type == 'IHDR') {
      width = _readUint32(bytes, dataStart);
      height = _readUint32(bytes, dataStart + 4);
      bitDepth = bytes[dataStart + 8];
      colorType = bytes[dataStart + 9];
      interlace = bytes[dataStart + 12];
    } else if (type == 'IDAT') {
      idat.add(bytes.sublist(dataStart, dataStart + length));
    } else if (type == 'IEND') {
      break;
    }
    offset = dataStart + length + 4;
  }

  if (width <= 0 || height <= 0) {
    throw StateError('missing IHDR');
  }
  if (bitDepth != 8) {
    throw StateError('unsupported bit depth $bitDepth');
  }
  if (interlace != 0) {
    throw StateError('interlaced PNG unsupported');
  }
  final channels = switch (colorType) {
    0 => 1,
    2 => 3,
    4 => 2,
    6 => 4,
    _ => throw StateError('unsupported colour type $colorType'),
  };

  final raw = Uint8List.fromList(ZLibCodec().decode(idat.toBytes()));
  final stride = width * channels;
  final pixels = Uint8List(width * height * 4);
  final previous = Uint8List(stride);
  final current = Uint8List(stride);
  var position = 0;

  for (var y = 0; y < height; y++) {
    if (position >= raw.length) {
      throw StateError('truncated image data');
    }
    final filter = raw[position++];
    for (var i = 0; i < stride; i++) {
      final a = i >= channels ? current[i - channels] : 0;
      final b = previous[i];
      final c = i >= channels ? previous[i - channels] : 0;
      current[i] = (raw[position + i] + _unfilter(filter, a, b, c)) & 0xFF;
    }
    position += stride;

    for (var x = 0; x < width; x++) {
      final base = x * channels;
      final out = (y * width + x) * 4;
      if (colorType == 0) {
        final g = current[base];
        pixels[out] = g;
        pixels[out + 1] = g;
        pixels[out + 2] = g;
        pixels[out + 3] = 255;
      } else if (colorType == 4) {
        final g = current[base];
        pixels[out] = g;
        pixels[out + 1] = g;
        pixels[out + 2] = g;
        pixels[out + 3] = current[base + 1];
      } else if (colorType == 2) {
        pixels[out] = current[base];
        pixels[out + 1] = current[base + 1];
        pixels[out + 2] = current[base + 2];
        pixels[out + 3] = 255;
      } else {
        pixels[out] = current[base];
        pixels[out + 1] = current[base + 1];
        pixels[out + 2] = current[base + 2];
        pixels[out + 3] = current[base + 3];
      }
    }
    previous.setAll(0, current);
  }

  return TextureProbe._(width, height, colorType, pixels);
}

int _readUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _unfilter(int filter, int a, int b, int c) {
  switch (filter) {
    case 0:
      return 0;
    case 1:
      return a;
    case 2:
      return b;
    case 3:
      return (a + b) >> 1;
    case 4:
      return _paeth(a, b, c);
    default:
      throw StateError('unsupported PNG filter $filter');
  }
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}
