import 'dart:typed_data';

/// Validate dimensions before image's WebP decoder can allocate frame buffers.
/// In particular, VP8X/ANMF dimensions do not constrain the inner VP8/VP8L
/// dimensions in image 4.8.0. Validate every frame and pass only the first
/// frame's checked image/alpha chunks to the decoder. This preserves Ugoira's
/// existing decodeFrame(0) behavior without recursive animation or metadata
/// parsers selecting a different stream after these checks.
({Uint8List bytes, int width, int height}) prepareUgoiraWebp(
  Uint8List bytes, {
  required int maxPixels,
}) => _WebpPreflight(bytes, maxPixels).prepare();

class _WebpPreflight {
  _WebpPreflight(this.bytes, this.maxPixels)
    : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  final int maxPixels;
  var _chunkCount = 0;

  ({Uint8List bytes, int width, int height}) prepare() {
    if (bytes.length < 12 ||
        _tag(0) != 'RIFF' ||
        _tag(8) != 'WEBP' ||
        data.getUint32(4, Endian.little) != bytes.length - 8) {
      throw const FormatException('动图 WebP 文件头或长度无效。');
    }
    var hasExtendedHeader = false;
    var animated = false;
    var hasAnimationHeader = false;
    var canvasWidth = 0;
    var canvasHeight = 0;
    _WebpChunk? staticImage;
    _WebpChunk? staticAlpha;
    _WebpFrame? firstFrame;
    for (final chunk in _chunks(12, bytes.length)) {
      switch (chunk.type) {
        case 'VP8X':
          if (hasExtendedHeader || chunk.start != 20 || chunk.length != 10) {
            throw const FormatException('动图 WebP 扩展文件头无效。');
          }
          final flags = bytes[chunk.start];
          if (flags & 0xc1 != 0 || _uint24(chunk.start + 1) != 0) {
            throw const FormatException('动图 WebP 扩展标志无效。');
          }
          hasExtendedHeader = true;
          animated = flags & 2 != 0;
          canvasWidth = _uint24(chunk.start + 4) + 1;
          canvasHeight = _uint24(chunk.start + 7) + 1;
          _checkPixels(canvasWidth, canvasHeight);
        case 'ANIM':
          if (!animated ||
              hasAnimationHeader ||
              firstFrame != null ||
              chunk.length != 6) {
            throw const FormatException('动图 WebP 动画头无效。');
          }
          hasAnimationHeader = true;
        case 'ANMF':
          if (!animated || !hasAnimationHeader || chunk.length < 16) {
            throw const FormatException('动图 WebP 动画帧头无效。');
          }
          final x = _uint24(chunk.start) * 2;
          final y = _uint24(chunk.start + 3) * 2;
          final width = _uint24(chunk.start + 6) + 1;
          final height = _uint24(chunk.start + 9) + 1;
          _checkPixels(width, height);
          if (bytes[chunk.start + 15] & 0xfc != 0 ||
              x + width > canvasWidth ||
              y + height > canvasHeight) {
            throw const FormatException('动图 WebP 帧超出画布或标志无效。');
          }
          final frame = _readFrame(chunk.start + 16, chunk.end);
          if (frame.width != width || frame.height != height) {
            throw const FormatException('动图 WebP 内外帧尺寸不一致。');
          }
          firstFrame ??= frame;
        case 'ALPH':
          if (animated || staticAlpha != null || staticImage != null) {
            throw const FormatException('动图 WebP 透明度块顺序无效。');
          }
          staticAlpha = chunk;
        case 'VP8 ' || 'VP8L':
          if (animated || staticImage != null) {
            throw const FormatException('动图 WebP 图像块重复或位置无效。');
          }
          staticImage = chunk;
        default:
          // Metadata and unknown chunks are bounded by _chunks and omitted
          // from the decoder input. Their parsers cannot allocate or recurse.
          break;
      }
    }
    if (animated) {
      if (!hasAnimationHeader || firstFrame == null) {
        throw const FormatException('动图 WebP 缺少动画帧。');
      }
    } else {
      firstFrame = _imageFrame(staticImage, staticAlpha);
      if (hasExtendedHeader &&
          (firstFrame.width != canvasWidth ||
              firstFrame.height != canvasHeight)) {
        throw const FormatException('动图 WebP 图像与画布尺寸不一致。');
      }
    }
    return (
      bytes: _canonicalImage(firstFrame),
      width: firstFrame.width,
      height: firstFrame.height,
    );
  }

  Iterable<_WebpChunk> _chunks(int start, int end) sync* {
    var position = start;
    while (position < end) {
      if (++_chunkCount > 65536 || end - position < 8) {
        throw const FormatException('动图 WebP 数据块不完整或数量超限。');
      }
      final length = data.getUint32(position + 4, Endian.little);
      final content = position + 8;
      final next = content + length + (length & 1);
      if (next > end) {
        throw const FormatException('动图 WebP 数据块越界。');
      }
      yield _WebpChunk(_tag(position), content, length);
      position = next;
    }
  }

  _WebpFrame _readFrame(int start, int end) {
    _WebpChunk? image;
    _WebpChunk? alpha;
    for (final chunk in _chunks(start, end)) {
      switch (chunk.type) {
        case 'ALPH':
          if (alpha != null || image != null) {
            throw const FormatException('动图 WebP 透明度块顺序无效。');
          }
          alpha = chunk;
        case 'VP8 ' || 'VP8L':
          if (image != null) {
            throw const FormatException('动图 WebP 帧包含重复图像块。');
          }
          image = chunk;
        case 'VP8X' || 'ANIM' || 'ANMF':
          throw const FormatException('动图 WebP 帧不能嵌套动画或画布。');
        default:
          break;
      }
    }
    return _imageFrame(image, alpha);
  }

  _WebpFrame _imageFrame(_WebpChunk? image, _WebpChunk? alpha) {
    if (image == null) {
      throw const FormatException('动图 WebP 缺少图像数据。');
    }
    final start = image.start;
    int width;
    int height;
    if (image.type == 'VP8L') {
      if (image.length < 5 || bytes[start] != 0x2f || alpha != null) {
        throw const FormatException('动图 WebP 无损图像头无效。');
      }
      final bits = data.getUint32(start + 1, Endian.little);
      if (bits >> 29 != 0) {
        throw const FormatException('动图 WebP 无损编码版本不受支持。');
      }
      width = (bits & 0x3fff) + 1;
      height = ((bits >> 14) & 0x3fff) + 1;
    } else {
      if (image.length < 10 || _uint24(start + 3) != 0x2a019d) {
        throw const FormatException('动图 WebP 有损图像头无效。');
      }
      final bits = _uint24(start);
      if (bits & 1 != 0 ||
          (bits >> 1) & 7 > 3 ||
          bits & 16 == 0 ||
          bits >> 5 > image.length - 10) {
        throw const FormatException('动图 WebP 有损帧参数无效。');
      }
      width = data.getUint16(start + 6, Endian.little);
      height = data.getUint16(start + 8, Endian.little);
      // image 4.8.0 uses the full 16-bit words as allocation dimensions. WebP
      // does not use VP8 scaling; reject those bits instead of masking them.
      if ((width | height) & 0xc000 != 0) {
        throw const FormatException('动图 WebP 缩放尺寸不受支持。');
      }
    }
    _checkPixels(width, height);
    if (alpha != null) {
      if (alpha.length < 1) {
        throw const FormatException('动图 WebP 透明度数据不完整。');
      }
      final flags = bytes[alpha.start];
      final method = flags & 3;
      if (flags & 0xc0 != 0 ||
          (flags >> 4) & 3 > 1 ||
          method > 1 ||
          (method == 0 && alpha.length != 1 + width * height) ||
          (method == 1 && alpha.length < 2)) {
        throw const FormatException('动图 WebP 透明度数据无效。');
      }
    }
    return _WebpFrame(image, alpha, width, height);
  }

  Uint8List _canonicalImage(_WebpFrame frame) {
    final image = _wholeChunk(frame.image);
    final alpha = frame.alpha == null ? null : _wholeChunk(frame.alpha!);
    final result = Uint8List(
      12 + image.length + (alpha == null ? 0 : 18 + alpha.length),
    );
    final header = ByteData.sublistView(result);
    result.setRange(0, 4, 'RIFF'.codeUnits);
    header.setUint32(4, result.length - 8, Endian.little);
    result.setRange(8, 12, 'WEBP'.codeUnits);
    var position = 12;
    if (alpha != null) {
      result.setRange(position, position + 4, 'VP8X'.codeUnits);
      header.setUint32(position + 4, 10, Endian.little);
      result[position + 8] = 0x10;
      _writeUint24(result, position + 12, frame.width - 1);
      _writeUint24(result, position + 15, frame.height - 1);
      position += 18;
      result.setRange(position, position + alpha.length, alpha);
      position += alpha.length;
    }
    result.setRange(position, result.length, image);
    return result;
  }

  Uint8List _wholeChunk(_WebpChunk chunk) => Uint8List.sublistView(
    bytes,
    chunk.start - 8,
    chunk.end + (chunk.length & 1),
  );

  void _checkPixels(int width, int height) {
    if (width <= 0 || height <= 0 || width * height > maxPixels) {
      throw const FormatException('动图 WebP 解码尺寸过大。');
    }
  }

  String _tag(int offset) =>
      String.fromCharCodes(Uint8List.sublistView(bytes, offset, offset + 4));

  int _uint24(int offset) =>
      bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16;

  static void _writeUint24(Uint8List bytes, int offset, int value) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >> 8) & 0xff;
    bytes[offset + 2] = (value >> 16) & 0xff;
  }
}

class _WebpChunk {
  const _WebpChunk(this.type, this.start, this.length);

  final String type;
  final int start;
  final int length;
  int get end => start + length;
}

class _WebpFrame {
  const _WebpFrame(this.image, this.alpha, this.width, this.height);

  final _WebpChunk image;
  final _WebpChunk? alpha;
  final int width;
  final int height;
}
