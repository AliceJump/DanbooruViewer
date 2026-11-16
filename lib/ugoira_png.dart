import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'ugoira_inflate.dart';

/// Check PNG's *inner* zlib stream before image's decoder can allocate it.
/// Only a 32 KiB DEFLATE history is retained during this validation. The exact
/// scanline size includes filters, packed samples, and all nonempty Adam7
/// passes. The emitted size shares an animation-wide budget, independently of
/// the outer ZIP's output budget. Only validated image/color chunks are passed
/// to image: its ancillary/APNG parsers must not reinterpret chunk boundaries
/// and select a different compressed stream from the one validated here.
({Uint8List bytes, int outputBytes}) prepareUgoiraPng(
  Uint8List bytes, {
  required int maxPixels,
  required int maxOutputBytes,
}) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33) {
    throw const FormatException('动图 PNG 文件头不完整。');
  }
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) {
      throw const FormatException('动图 PNG 文件头无效。');
    }
  }
  final data = ByteData.sublistView(bytes);
  var position = 8;
  var chunks = 0;
  var expected = 0;
  var sawHeader = false;
  var sawEnd = false;
  var compressedLength = 0;
  var colorType = 0;
  var paletteEntries = 0;
  Uint8List? headerChunk;
  Uint8List? paletteChunk;
  Uint8List? transparencyChunk;
  Uint8List? gammaChunk;
  final blocks = <({int start, int length})>[];
  while (position + 12 <= bytes.length) {
    if (++chunks > 65536) {
      throw const FormatException('动图 PNG 数据块数量超出限制。');
    }
    final size = data.getUint32(position);
    final start = position + 8;
    final end = start + size;
    if (end + 4 > bytes.length) {
      throw const FormatException('动图 PNG 数据块不完整。');
    }
    final type = String.fromCharCodes(bytes.sublist(position + 4, start));
    if (!sawHeader && type != 'IHDR') {
      throw const FormatException('动图 PNG 缺少首个图像头。');
    }
    if (getCrc32(Uint8List.sublistView(bytes, position + 4, end)) !=
        data.getUint32(end)) {
      throw const FormatException('动图 PNG 数据块校验失败。');
    }
    if (type == 'IHDR') {
      if (sawHeader || size != 13) {
        throw const FormatException('动图 PNG 图像头无效。');
      }
      sawHeader = true;
      final width = data.getUint32(start);
      final height = data.getUint32(start + 4);
      final depth = bytes[start + 8];
      final color = bytes[start + 9];
      colorType = color;
      headerChunk = Uint8List.sublistView(bytes, position, end + 4);
      final channels = switch (color) {
        0 || 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        _ => 0,
      };
      final validDepth = switch (color) {
        0 => const [1, 2, 4, 8, 16].contains(depth),
        3 => const [1, 2, 4, 8].contains(depth),
        2 || 4 || 6 => const [8, 16].contains(depth),
        _ => false,
      };
      if (width == 0 ||
          height == 0 ||
          width > maxPixels ||
          height > maxPixels ||
          width * height > maxPixels) {
        throw const FormatException('动图 PNG 解码尺寸过大。');
      }
      if (!validDepth ||
          bytes[start + 10] != 0 ||
          bytes[start + 11] != 0 ||
          bytes[start + 12] > 1) {
        throw const FormatException('动图 PNG 编码格式不受支持。');
      }
      final bitsPerPixel = channels * depth;
      int passSize(int x, int y, int dx, int dy) {
        if (width <= x || height <= y) return 0;
        final columns = (width - x + dx - 1) ~/ dx;
        final rows = (height - y + dy - 1) ~/ dy;
        return rows * (1 + (columns * bitsPerPixel + 7) ~/ 8);
      }

      expected = bytes[start + 12] == 0
          ? passSize(0, 0, 1, 1)
          : passSize(0, 0, 8, 8) +
                passSize(4, 0, 8, 8) +
                passSize(0, 4, 4, 8) +
                passSize(2, 0, 4, 4) +
                passSize(0, 2, 2, 4) +
                passSize(1, 0, 2, 2) +
                passSize(0, 1, 1, 2);
      if (expected > maxOutputBytes) {
        throw const FormatException('动图 PNG 累计解压大小超出限制。');
      }
    } else if (type == 'PLTE') {
      if (paletteChunk != null || size == 0 || size > 768 || size % 3 != 0) {
        throw const FormatException('动图 PNG 调色板无效。');
      }
      paletteEntries = size ~/ 3;
      paletteChunk = Uint8List.sublistView(bytes, position, end + 4);
    } else if (type == 'tRNS') {
      final valid = switch (colorType) {
        0 => size == 2,
        2 => size == 6,
        3 => size > 0 && size <= 256,
        _ => false,
      };
      if (transparencyChunk != null || !valid) {
        throw const FormatException('动图 PNG 透明度数据无效。');
      }
      transparencyChunk = Uint8List.sublistView(bytes, position, end + 4);
    } else if (type == 'gAMA') {
      if (gammaChunk != null || size != 4) {
        throw const FormatException('动图 PNG 颜色数据无效。');
      }
      gammaChunk = Uint8List.sublistView(bytes, position, end + 4);
    } else if (type == 'IDAT') {
      blocks.add((start: start, length: size));
      compressedLength += size;
    } else if (type == 'IEND') {
      if (size != 0) throw const FormatException('动图 PNG 结束标记无效。');
      sawEnd = true;
      break;
    }
    position = end + 4;
  }
  if (!sawHeader || !sawEnd || compressedLength < 6) {
    throw const FormatException('动图 PNG 图片数据不完整。');
  }
  if (colorType == 3 &&
      (paletteEntries == 0 ||
          (transparencyChunk != null &&
              transparencyChunk.length - 12 > paletteEntries))) {
    throw const FormatException('动图 PNG 调色板与透明度不匹配。');
  }
  final compressed = Uint8List(compressedLength);
  var offset = 0;
  for (final block in blocks) {
    compressed.setRange(offset, offset + block.length, bytes, block.start);
    offset += block.length;
  }
  final cmf = compressed[0];
  final flg = compressed[1];
  if (cmf & 15 != 8 ||
      cmf >> 4 > 7 ||
      (cmf * 256 + flg) % 31 != 0 ||
      flg & 32 != 0) {
    throw const FormatException('动图 PNG 压缩流头无效。');
  }
  // Inflate rewinds unused whole bytes at EOB, so the final input position
  // also requires exactly one checked zlib stream, without a concatenated
  // stream or trailing payload.
  final input = InputMemoryStream(compressed)..skip(2);
  final output = _PngInflateCounter(expected);
  inflateUgoiraStream(input, output);
  if (input.position != compressed.length - 4 ||
      output.length != expected ||
      output.adler32 !=
          ByteData.sublistView(compressed).getUint32(compressed.length - 4)) {
    throw const FormatException('动图 PNG 解压长度或校验值不正确。');
  }
  final idatHeader = Uint8List(8);
  ByteData.sublistView(idatHeader).setUint32(0, compressed.length);
  idatHeader.setRange(4, 8, 'IDAT'.codeUnits);
  final idatCrc = Uint8List(4);
  ByteData.sublistView(
    idatCrc,
  ).setUint32(0, getCrc32(compressed, getCrc32('IDAT'.codeUnits)));
  final canonical = BytesBuilder(copy: false)
    ..add(signature)
    ..add(headerChunk!);
  if (gammaChunk != null) canonical.add(gammaChunk);
  if (paletteChunk != null) canonical.add(paletteChunk);
  if (transparencyChunk != null) canonical.add(transparencyChunk);
  canonical
    ..add(idatHeader)
    ..add(compressed)
    ..add(idatCrc)
    ..add(const [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);
  return (bytes: canonical.takeBytes(), outputBytes: output.length);
}

/// Inflate needs back-references but not the entire emitted buffer. A ring
/// retains only its maximum 32 KiB window; no decoded image is allocated here.
class _PngInflateCounter extends OutputStream {
  _PngInflateCounter(this.limit) : super(byteOrder: ByteOrder.bigEndian);

  final int limit;
  final _history = Uint8List(32768);
  int _length = 0;
  int _adlerA = 1;
  int _adlerB = 0;
  int _adlerCount = 0;

  @override
  int get length => _length;

  int get adler32 => (_adlerB % 65521) * 65536 + _adlerA % 65521;

  void _reserve(int count) {
    if (count < 0 || count > limit - length) {
      throw const FormatException('动图 PNG 实际解压大小超出扫描行限制。');
    }
  }

  void _append(int value) {
    final byte = value & 255;
    _history[_length++ & 32767] = byte;
    _adlerA += byte;
    _adlerB += _adlerA;
    if (++_adlerCount == 3800) {
      _adlerA %= 65521;
      _adlerB %= 65521;
      _adlerCount = 0;
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _append(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    for (var i = 0; i < count; i++) {
      _append(bytes[i]);
    }
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    while (!stream.isEOS) {
      _append(stream.readByte());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final from = start < 0 ? length + start : start;
    final to = end == null ? length : (end < 0 ? length + end : end);
    if (from < 0 ||
        from < length - _history.length ||
        to < from ||
        to > length) {
      throw const FormatException('动图 PNG 压缩引用无效。');
    }
    return Uint8List.fromList([
      for (var i = from; i < to; i++) _history[i & 32767],
    ]);
  }

  @override
  void clear() {
    _length = 0;
    _adlerA = 1;
    _adlerB = 0;
    _adlerCount = 0;
  }

  @override
  void flush() {}
}
