import 'dart:typed_data';

/// Validate every field which the decoder uses before or during BMP allocation.
/// Only its implemented uncompressed/bitfield layouts are admitted. Palette
/// counts must fit both the bit depth and the actual bytes before pixel data.
({Uint8List bytes, int width, int height}) prepareUgoiraBmp(
  Uint8List bytes, {
  required int maxPixels,
}) {
  Never invalid(String reason) => throw FormatException('BMP 帧$reason。');
  if (bytes.length < 54 || bytes[0] != 0x42 || bytes[1] != 0x4d) {
    invalid('文件头不完整');
  }
  final data = ByteData.sublistView(bytes);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  int i32(int offset) => data.getInt32(offset, Endian.little);
  int u16(int offset) => data.getUint16(offset, Endian.little);
  final declaredLength = u32(2);
  final imageOffset = u32(10);
  final headerSize = u32(14);
  if (!const {40, 52, 56, 108, 124}.contains(headerSize) ||
      14 + headerSize > bytes.length) {
    invalid('头格式不支持或已截断');
  }
  final width = i32(18);
  final signedHeight = i32(22);
  final height = signedHeight.abs();
  if (width <= 0 || height <= 0 || width * height > maxPixels) {
    invalid('解码尺寸过大或无效');
  }
  final depth = u16(28);
  final compression = u32(30);
  if (u16(26) != 1 || !const {1, 4, 8, 16, 24, 32}.contains(depth)) {
    invalid('位深或颜色平面不支持');
  }
  // BmpDecoder does not implement RLE, embedded JPEG/PNG, or CMYK. Its BMP
  // encoder also emits 24-bit BI_BITFIELDS, which its decoder reads as BGR.
  if (!const {0, 3, 6}.contains(compression) ||
      (compression != 0 && depth <= 8) ||
      (compression == 6 && headerSize == 52)) {
    invalid('压缩格式不支持');
  }
  final masksLength = headerSize == 40 && compression != 0
      ? (compression == 6 ? 16 : 12)
      : 0;
  final paletteOffset = 14 + headerSize + masksLength;
  final usedColors = u32(46);
  final paletteColors = depth <= 8
      ? (usedColors == 0 ? 1 << depth : usedColors)
      : usedColors;
  if (depth <= 8 && paletteColors > 1 << depth) {
    invalid('调色板条目数超过位深范围');
  }
  final paletteEnd = paletteOffset + paletteColors * 4;
  if (paletteEnd > bytes.length ||
      imageOffset < paletteEnd ||
      imageOffset > bytes.length ||
      imageOffset > 0x7fffffff) {
    invalid('调色板或像素偏移超出文件范围');
  }
  if (headerSize > 40 || compression != 0) {
    final maskCount = headerSize == 52 || (headerSize == 40 && compression == 3)
        ? 3
        : 4;
    final maskEnd = 54 + maskCount * 4;
    if (maskEnd > imageOffset || maskEnd > bytes.length) {
      invalid('颜色掩码已截断');
    }
    // Skip masks on indexed extended headers: the decoder uses the palette.
    if (depth > 8 && compression != 0) {
      var occupied = 0;
      for (var index = 0; index < maskCount; index++) {
        final mask = u32(54 + index * 4);
        // The image package writes an unused high-byte alpha mask for its
        // 24-bit BMP output. Only RGB masks participate in 24-bit decoding.
        final allowed = depth == 32 || (depth == 24 && index == 3)
            ? 0xffffffff
            : (1 << depth) - 1;
        if ((index < 3 && mask == 0) ||
            mask > allowed ||
            (mask & occupied) != 0) {
          invalid('颜色掩码无效');
        }
        if (mask != 0) {
          var normalized = mask;
          while (normalized.isEven) {
            normalized ~/= 2;
          }
          if ((normalized & (normalized + 1)) != 0) {
            invalid('颜色掩码不连续');
          }
        }
        occupied |= mask;
      }
    }
  }
  final rowBytes = ((width * depth + 31) ~/ 32) * 4;
  final pixelEnd = imageOffset + rowBytes * height;
  if (pixelEnd > bytes.length ||
      (declaredLength != 0 &&
          (declaredLength < pixelEnd || declaredLength > bytes.length))) {
    invalid('像素数据已截断');
  }
  var prepared = bytes;
  if (headerSize == 52) {
    // image 4.13.1 reads four masks for every header > 40. BITMAPV2INFOHEADER
    // only has three: use a V5 header with an explicit zero alpha mask so it
    // cannot read palette/pixel bytes as that mask. V5 is also the decoder's
    // supported zero-alpha-mask path for opaque RGB bitfields.
    const addedHeaderBytes = 124 - 52;
    prepared = Uint8List(bytes.length + addedHeaderBytes)
      ..setRange(0, 66, bytes)
      ..setRange(138, bytes.length + addedHeaderBytes, bytes, 66);
    ByteData.sublistView(prepared)
      ..setUint32(
        2,
        declaredLength == 0 ? 0 : declaredLength + addedHeaderBytes,
        Endian.little,
      )
      ..setUint32(10, imageOffset + addedHeaderBytes, Endian.little)
      ..setUint32(14, 124, Endian.little);
  }
  if (compression == 6) {
    // The decoder handles four masks but only dispatches its 32-bit pixel
    // path for BI_BITFIELDS. Normalize the equivalent validated alpha layout.
    prepared = Uint8List.fromList(prepared);
    final preparedData = ByteData.sublistView(prepared)
      ..setUint32(30, 3, Endian.little);
    if (headerSize == 40) {
      // The four trailing masks already occupy these additional 16 bytes.
      preparedData.setUint32(14, 56, Endian.little);
    }
  }
  return (bytes: prepared, width: width, height: height);
}
