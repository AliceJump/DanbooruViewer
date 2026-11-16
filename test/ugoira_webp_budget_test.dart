import 'dart:convert';
import 'dart:typed_data';

import 'package:danbooru_viewer/ugoira_webp_budget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// Independent Pillow/libwebp lossless fixture (2x1 opaque red).
const _lossless = 'UklGRhwAAABXRUJQVlA4TA8AAAAvAQAAAAcQ/Y/+ByKi/wEA';
// Independent Pillow/libwebp lossy fixture: 16x16 red, checkerboard alpha
// 192 on even x+y and 128 on odd. The ALPH payload uses method 1 (VP8L
// compression), not raw alpha.
const _compressedAlpha =
    'UklGRnAAAABXRUJQVlA4WAoAAAAQAAAADwAADwAAQUxQSBUAAAABEBIQ103zTlQjgmCSptqOkfqcfwcAVlA4IDQAAAAwAgCdASoQABAAAMASJaACdLoB+AH4AARoAAD++iGX/3easNN39a3/9aOfron+tHP/WVgA';
// Independent Pillow/libwebp method=6 lossless gradient, 16x16. Pixel (x,y)
// is (13*x,17*y,19*(x^y) mod 256,255).
const _gradient =
    'UklGRqAAAABXRUJQVlA4TJQAAAAvD8ADALkyRPQ/dhHR/wCDtm0EmUL5s/219xSmwUkkSYJ0r6Hw0Dy3i//UHHsRi399hMK2bZuObDvJG1z2dyM2XpLDsCOwCGAB4AEY/ojY9BDMZ0YA+BAAgOELXlyYBoFPRoVg0SF4wYOGUSFaNIIfcQNACw5TfUpMX+7e/8QgqMX0xewfXd+RdGL6YvaP2ODgZbIB';

void main() {
  test('three-to-five-byte constant streams remain valid with lookahead', () {
    for (final (red, alpha) in [(0, 0), (0, 255), (255, 255)]) {
      final stream = _constantStream(red: red, alpha: alpha);
      expect(stream.length, inInclusiveRange(3, 5));
      final checked = checkUgoiraWebpLosslessBudget(
        stream,
        width: 1,
        height: 1,
      );
      expect(checked.usedGroups, 1);
      expect(checked.auxiliaryPixels, 0);
      final pixel = img.decodeWebP(_webp(stream, 1, 1))!.getPixel(0, 0);
      expect((pixel.r, pixel.g, pixel.b, pixel.a), (red, 0, 0, alpha));
    }
  });

  test(
    'external lossless color indexing retains the actual decoded pixels',
    () {
      final webp = base64Decode(_lossless);
      final payload = _payload(webp, 'VP8L');
      final checked = checkUgoiraWebpLosslessBudget(
        Uint8List.sublistView(payload, 5),
        width: 2,
        height: 1,
      );
      expect(checked.usedGroups, 1);
      expect(checked.auxiliaryPixels, greaterThan(0));
      final image = img.decodeWebP(webp)!;
      expect((image.width, image.height), (2, 1));
      expect(image.getPixel(0, 0).r, 255);
    },
  );

  test('compressed ALPH uses the same bounded prefix and keeps alpha', () {
    final webp = base64Decode(_compressedAlpha);
    final payload = _payload(webp, 'ALPH');
    expect(payload[0] & 3, 1);
    final checked = checkUgoiraWebpLosslessBudget(
      Uint8List.sublistView(payload, 1),
      width: 16,
      height: 16,
    );
    expect(checked.usedGroups, greaterThan(0));
    // This compressed-alpha fixture has a direct Huffman image stream; it
    // needs no predictor/palette/meta auxiliary image.
    expect(checked.auxiliaryPixels, 0);
    final image = img.decodeWebP(webp)!;
    expect(image.getPixel(0, 0).a, 192);
    expect(image.getPixel(1, 0).a, 128);
  });

  test(
    'external lossless gradient keeps every pixel after prefix validation',
    () {
      final webp = base64Decode(_gradient);
      final payload = _payload(webp, 'VP8L');
      final checked = checkUgoiraWebpLosslessBudget(
        Uint8List.sublistView(payload, 5),
        width: 16,
        height: 16,
      );
      expect(checked.auxiliaryPixels, greaterThan(0));
      final image = img.decodeWebP(webp)!;
      for (final pixel in image) {
        expect(
          (pixel.r, pixel.g, pixel.b, pixel.a),
          (13 * pixel.x, 17 * pixel.y, (19 * (pixel.x ^ pixel.y)) % 256, 255),
        );
      }
    },
  );

  test(
    'color indexing updates widths of later predictor and color transforms',
    () {
      final bits = _Bits()
        ..write(1, 1)
        ..write(3, 2)
        ..write(1, 8); // Two palette entries, compress width by eight.
      _auxiliaryConstant(bits, red: 255, alpha: 255);
      for (final type in [0, 1]) {
        bits
          ..write(1, 1)
          ..write(type, 2)
          ..write(0, 3); // 4x4 transform blocks after width is reduced to one.
        _auxiliaryConstant(bits);
      }
      bits
        ..write(1, 1)
        ..write(2, 2) // Subtract green, the fourth distinct transform.
        ..write(0, 1)
        ..write(0, 1)
        ..write(0, 1);
      _constantTrees(bits);
      final stream = bits.bytes;
      final checked = checkUgoiraWebpLosslessBudget(
        stream,
        width: 8,
        height: 4,
      );
      // Palette 2 pixels + two 1-pixel auxiliary images, decoded twice.
      expect(checked.auxiliaryPixels, 8);
      final image = img.decodeWebP(_webp(stream, 8, 4))!;
      expect((image.width, image.height), (8, 4));
      expect(image.getPixel(0, 0).r, 255);
    },
  );

  test(
    'small real two-group stream decodes and rejects a one-group budget',
    () {
      final stream = _twoGroupStream();
      final checked = checkUgoiraWebpLosslessBudget(
        stream,
        width: 8,
        height: 4,
      );
      expect(checked.usedGroups, 2);
      expect(checked.auxiliaryPixels, 4);
      final image = img.decodeWebP(_webp(stream, 8, 4))!;
      expect(image.getPixel(0, 0).r, 255);
      expect(image.getPixel(7, 0).b, 255);
      expect(
        () => checkUgoiraWebpLosslessBudget(
          stream,
          width: 8,
          height: 4,
          maxHuffmanGroups: 1,
        ),
        _formatContaining('表组数量'),
      );
    },
  );

  test('table budget includes more than the initial table allocation', () {
    final stream = _constantStream(red: 255, alpha: 255);
    expect(
      () => checkUgoiraWebpLosslessBudget(
        stream,
        width: 1,
        height: 1,
        maxHuffmanTableEntries: 2954, // Only the initial cache-free group.
      ),
      _formatContaining('表分配预算'),
    );
  });

  test('largest valid color cache participates in the table reservation', () {
    final ordinary = _constantStream(red: 255, alpha: 255);
    final cached = _constantStream(red: 255, alpha: 255, cacheBits: 11);
    final small = checkUgoiraWebpLosslessBudget(ordinary, width: 1, height: 1);
    final large = checkUgoiraWebpLosslessBudget(cached, width: 1, height: 1);
    expect(large.colorCacheBits, 11);
    expect(large.tableEntries, greaterThan(small.tableEntries));
    expect(img.decodeWebP(_webp(cached, 1, 1))!.getPixel(0, 0).r, 255);
    expect(
      () => checkUgoiraWebpLosslessBudget(
        cached,
        width: 1,
        height: 1,
        maxHuffmanTableEntries: small.tableEntries,
      ),
      _formatContaining('表分配预算'),
    );
  });

  test(
    'encoded group limit rejects a tiny sparse prefix before main tables',
    () {
      // 1x1 auxiliary image containing group 4096; no main Huffman tables.
      // This intentionally never calls the full decoder on the incomplete input.
      final stream = base64Decode('hChE9D8A');
      expect(
        () => checkUgoiraWebpLosslessBudget(stream, width: 1, height: 1),
        _formatContaining('编码表数量'),
      );
    },
  );

  test(
    'auxiliary pixels are checked before invoking even a one-group decoder',
    () {
      expect(
        () => checkUgoiraWebpLosslessBudget(
          // transform=0, cache=0, meta=1, precision=0, aux cache=0;
          // no auxiliary tables need to be parsed to reject its 2-pass cost.
          Uint8List.fromList([4]),
          width: 1,
          height: 1,
          maxAuxiliaryPixels: 1,
        ),
        _formatContaining('辅助图像解码预算'),
      );
      expect(
        () => checkUgoiraWebpLosslessBudget(
          _twoGroupStream(),
          width: 8,
          height: 4,
          maxAuxiliaryPixels: 3,
        ),
        _formatContaining('辅助图像解码预算'),
      );
    },
  );

  test('auxiliary table reservation precedes malformed table decoding', () {
    expect(
      () => checkUgoiraWebpLosslessBudget(
        Uint8List.fromList([4]),
        width: 1,
        height: 1,
        maxHuffmanTableEntries: 1,
      ),
      _formatContaining('表分配预算'),
    );
  });

  test('lookahead padding and adjacent backing bytes never count as payload', () {
    // This prefix consumes 41 bits. Removing its final zero byte must fail,
    // even though zero lookahead would otherwise complete the same Huffman code.
    final complete = base64Decode('hChE9D8A');
    final truncated = Uint8List.sublistView(complete, 0, complete.length - 1);
    expect(
      () => checkUgoiraWebpLosslessBudget(truncated, width: 1, height: 1),
      _formatContaining('截断'),
    );
  });

  test(
    'duplicate transforms and invalid color-cache sizes fail explicitly',
    () {
      final duplicate = _Bits()
        ..write(1, 1)
        ..write(2, 2)
        ..write(1, 1)
        ..write(2, 2);
      expect(
        () =>
            checkUgoiraWebpLosslessBudget(duplicate.bytes, width: 1, height: 1),
        _formatContaining('重复图像变换'),
      );
      for (final value in [0, 12, 15]) {
        final invalid = _Bits()
          ..write(0, 1)
          ..write(1, 1)
          ..write(value, 4);
        expect(
          () =>
              checkUgoiraWebpLosslessBudget(invalid.bytes, width: 1, height: 1),
          _formatContaining('颜色缓存参数'),
        );
      }
    },
  );
}

Matcher _formatContaining(String text) => throwsA(
  isA<FormatException>().having(
    (error) => error.message,
    'reason',
    contains(text),
  ),
);

Uint8List _constantStream({int red = 0, int alpha = 0, int cacheBits = 0}) {
  final bits = _Bits()..write(0, 1);
  bits.write(cacheBits == 0 ? 0 : 1, 1);
  if (cacheBits != 0) bits.write(cacheBits, 4);
  bits.write(0, 1);
  _constantTrees(bits, red: red, alpha: alpha);
  return bits.bytes;
}

Uint8List _twoGroupStream() {
  final bits = _Bits()
    ..write(0, 1)
    ..write(0, 1)
    ..write(1, 1)
    ..write(0, 3)
    ..write(0, 1); // Auxiliary color cache disabled, no recursive meta flag.
  // Auxiliary green tree uses two literals: group index 0 then index 1.
  bits
    ..write(1, 1)
    ..write(1, 1)
    ..write(0, 1)
    ..write(0, 1)
    ..write(1, 8);
  for (final value in [0, 0, 255, 0]) {
    _constantTree(bits, value);
  }
  bits
    ..write(0, 1)
    ..write(1, 1);
  _constantTrees(bits, red: 255, alpha: 255);
  _constantTrees(bits, blue: 255, alpha: 255);
  return bits.bytes;
}

void _auxiliaryConstant(_Bits bits, {int red = 0, int alpha = 0}) {
  bits.write(0, 1);
  _constantTrees(bits, red: red, alpha: alpha);
}

void _constantTrees(_Bits bits, {int red = 0, int blue = 0, int alpha = 0}) {
  for (final value in [0, red, blue, alpha, 0]) {
    _constantTree(bits, value);
  }
}

void _constantTree(_Bits bits, int value) {
  bits
    ..write(1, 1)
    ..write(0, 1)
    ..write(value < 2 ? 0 : 1, 1)
    ..write(value, value < 2 ? 1 : 8);
}

Uint8List _webp(Uint8List stream, int width, int height) {
  final payloadLength = 5 + stream.length;
  final bytes = Uint8List(20 + payloadLength + (payloadLength & 1));
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, 'WEBPVP8L'.codeUnits);
  data.setUint32(16, payloadLength, Endian.little);
  bytes[20] = 0x2f;
  data.setUint32(21, (width - 1) | (height - 1) << 14 | 1 << 28, Endian.little);
  bytes.setRange(25, 25 + stream.length, stream);
  return bytes;
}

Uint8List _payload(Uint8List bytes, String type) {
  final data = ByteData.sublistView(bytes);
  for (var position = 12; position + 8 <= bytes.length;) {
    final size = data.getUint32(position + 4, Endian.little);
    if (String.fromCharCodes(bytes.sublist(position, position + 4)) == type) {
      return Uint8List.sublistView(bytes, position + 8, position + 8 + size);
    }
    position += 8 + size + (size & 1);
  }
  throw StateError('Missing $type fixture chunk');
}

class _Bits {
  final _bits = <int>[];

  void write(int value, int count) {
    for (var i = 0; i < count; i++) {
      _bits.add((value >> i) & 1);
    }
  }

  Uint8List get bytes {
    final output = Uint8List((_bits.length + 7) ~/ 8);
    for (var i = 0; i < _bits.length; i++) {
      output[i >> 3] |= _bits[i] << (i & 7);
    }
    return output;
  }
}
