import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/ugoira_bmp.dart';
import 'package:danbooru_viewer/ugoira_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _bmp({
  int width = 2,
  int height = 1,
  int depth = 24,
  int headerSize = 40,
  int compression = 0,
  int usedColors = 0,
  int? paletteEntries,
}) {
  final palette =
      paletteEntries ??
      (depth <= 8 ? (usedColors == 0 ? 1 << depth : usedColors) : 0);
  final masksLength = headerSize == 40 && compression != 0
      ? (compression == 6 ? 16 : 12)
      : 0;
  final offset = 14 + headerSize + masksLength + palette * 4;
  final rows = ((width * depth + 31) ~/ 32) * 4 * height.abs();
  final bytes = Uint8List(offset + rows);
  final data = ByteData.sublistView(bytes)
    ..setUint16(0, 0x4d42, Endian.little)
    ..setUint32(2, bytes.length, Endian.little)
    ..setUint32(10, offset, Endian.little)
    ..setUint32(14, headerSize, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, depth, Endian.little)
    ..setUint32(30, compression, Endian.little)
    ..setUint32(34, rows, Endian.little)
    ..setUint32(46, usedColors, Endian.little);
  if (headerSize > 40 || compression != 0) {
    data
      ..setUint32(54, depth == 16 ? 0x7c00 : 0xff0000, Endian.little)
      ..setUint32(58, depth == 16 ? 0x03e0 : 0xff00, Endian.little)
      ..setUint32(62, depth == 16 ? 0x001f : 0xff, Endian.little);
    if (headerSize >= 56 || compression == 6) {
      data.setUint32(66, depth == 32 ? 0xff000000 : 0, Endian.little);
    }
  }
  final paletteOffset = 14 + headerSize + masksLength;
  for (var index = 0; index < palette; index++) {
    bytes[paletteOffset + index * 4 + 2] = index == 0 ? 255 : 0;
    bytes[paletteOffset + index * 4 + 1] = index == 0 ? 0 : 255;
  }
  if (depth == 24) {
    for (var row = 0; row < height.abs(); row++) {
      bytes[offset + row * ((width * depth + 31) ~/ 32) * 4 + 2] = 255;
    }
  }
  return bytes;
}

Uint8List _zip(Uint8List bmp) => Uint8List.fromList(
  ZipEncoder().encode(Archive()..add(ArchiveFile.bytes('000.bmp', bmp))),
);

void _set32(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);

void main() {
  test('ordinary bottom-up and top-down RGB retain pixels and convert', () {
    for (final height in [2, -2]) {
      final bmp = _bmp(height: height);
      final prepared = prepareUgoiraBmp(bmp, maxPixels: 4);
      expect((prepared.width, prepared.height), (2, 2));
      expect(img.decodeBmp(prepared.bytes)!.getPixel(0, 0).r, 255);
      final gif = img.decodeGif(mergeUgoiraBytesToGifSync(_zip(bmp)))!;
      expect((gif.width, gif.height), (2, 2));
    }
  });

  test(
    'indexed BMP admits implicit and shortened palettes within bit depth',
    () {
      for (final depth in [1, 4, 8]) {
        for (final usedColors in [0, 2]) {
          final bmp = _bmp(depth: depth, usedColors: usedColors);
          final prepared = prepareUgoiraBmp(bmp, maxPixels: 2);
          expect(img.decodeBmp(prepared.bytes)!.getPixel(0, 0).r, 255);
          expect(
            img.decodeGif(mergeUgoiraBytesToGifSync(_zip(bmp))),
            isNotNull,
          );
        }
      }
    },
  );

  test('palette count must fit bit depth before the decoder allocates it', () {
    final bmp = _bmp(depth: 4, paletteEntries: 17);
    _set32(bmp, 46, 17);
    expect(
      () => prepareUgoiraBmp(bmp, maxPixels: 2),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('调色板条目数'),
        ),
      ),
    );
    expect(
      () => mergeUgoiraBytesToGifSync(_zip(bmp)),
      throwsA(isA<FormatException>()),
    );
  });

  test('palette range must fit before pixels and within actual input', () {
    final missing = _bmp(depth: 8, usedColors: 2, paletteEntries: 1);
    final overlap = _bmp(depth: 8, usedColors: 2);
    _set32(overlap, 10, 54);
    for (final bmp in [missing, overlap]) {
      expect(
        () => prepareUgoiraBmp(bmp, maxPixels: 2),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test(
    'supported bitfield headers include safe normalization of 52-byte DIB',
    () {
      for (final depth in [16, 32]) {
        for (final size in [40, 52, 56, 108, 124]) {
          final bmp = _bmp(depth: depth, headerSize: size, compression: 3);
          if (size == 52) {
            final pixels = ByteData.sublistView(bmp);
            final offset = pixels.getUint32(10, Endian.little);
            if (depth == 16) {
              pixels.setUint16(offset, 0x7c00, Endian.little);
            } else {
              pixels.setUint32(offset, 0x00ff0000, Endian.little);
            }
          }
          final prepared = prepareUgoiraBmp(bmp, maxPixels: 2);
          expect(img.decodeBmp(prepared.bytes)!.width, 2);
          if (size == 52) {
            expect(
              ByteData.sublistView(prepared.bytes).getUint32(14, Endian.little),
              124,
            );
            expect(prepared.bytes.length, bmp.length + 72);
            final pixel = img.decodeBmp(prepared.bytes)!.getPixel(0, 0);
            expect((pixel.r, pixel.g, pixel.b, pixel.a), (255, 0, 0, 255));
          }
          expect(
            img.decodeGif(mergeUgoiraBytesToGifSync(_zip(bmp))),
            isNotNull,
          );
        }
      }
    },
  );

  test('image package RGB and RGBA encoder output remains compatible', () {
    for (final channels in [3, 4]) {
      final bmp = img.encodeBmp(
        img.Image(width: 3, height: 2, numChannels: channels),
      );
      final prepared = prepareUgoiraBmp(bmp, maxPixels: 6);
      expect(img.decodeBmp(prepared.bytes)!.width, 3);
      expect(img.decodeGif(mergeUgoiraBytesToGifSync(_zip(bmp))), isNotNull);
    }
  });

  test('alpha bitfields normalize to the supported equivalent pixel path', () {
    for (final size in [40, 56, 108, 124]) {
      final bmp = _bmp(depth: 32, headerSize: size, compression: 6);
      final offset = ByteData.sublistView(bmp).getUint32(10, Endian.little);
      _set32(bmp, offset, 0x80402010);
      final prepared = prepareUgoiraBmp(bmp, maxPixels: 2);
      final pixel = img.decodeBmp(prepared.bytes)!.getPixel(0, 0);
      expect((pixel.r, pixel.g, pixel.b, pixel.a), (64, 32, 16, 128));
      expect(img.decodeGif(mergeUgoiraBytesToGifSync(_zip(bmp))), isNotNull);
    }
  });

  test('small dimensions consume the caller remaining pixel budget', () {
    final bmp = _bmp();
    expect(
      () => prepareUgoiraBmp(bmp, maxPixels: 1),
      throwsA(isA<FormatException>()),
    );
    final zero = Uint8List.fromList(bmp);
    _set32(zero, 22, 0);
    final negative = Uint8List.fromList(bmp);
    _set32(negative, 18, 0xffffffff);
    for (final invalid in [zero, negative]) {
      expect(
        () => prepareUgoiraBmp(invalid, maxPixels: 2),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test(
    'unsupported planes, bit depths and compressed layouts fail clearly',
    () {
      final fixtures = <Uint8List>[];
      for (final (offset, value) in [(26, 2), (28, 0), (28, 2), (28, 64)]) {
        final bmp = _bmp();
        ByteData.sublistView(bmp).setUint16(offset, value, Endian.little);
        fixtures.add(bmp);
      }
      for (final compression in [1, 2, 4, 5, 7, 0xffffffff]) {
        final bmp = _bmp();
        _set32(bmp, 30, compression);
        fixtures.add(bmp);
      }
      for (final bmp in fixtures) {
        expect(
          () => prepareUgoiraBmp(bmp, maxPixels: 2),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  test('truncated headers, rows and file offsets cannot reach the decoder', () {
    final bmp = _bmp();
    final invalidOffset = Uint8List.fromList(bmp);
    _set32(invalidOffset, 10, 0xffffffff);
    final shortLength = Uint8List.fromList(bmp);
    _set32(shortLength, 2, 54);
    final longLength = Uint8List.fromList(bmp);
    _set32(longLength, 2, bmp.length + 1);
    final shortMask = Uint8List.fromList(_bmp(depth: 32, headerSize: 56));
    _set32(shortMask, 10, 54);
    for (final invalid in [
      Uint8List(12),
      bmp.sublist(0, bmp.length - 1),
      invalidOffset,
      shortLength,
      longLength,
      shortMask,
    ]) {
      expect(
        () => prepareUgoiraBmp(invalid, maxPixels: 2),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('bitfield masks must be contiguous non-overlapping valid channels', () {
    for (final mask in [0, 0x101, 0xff00, 0x1000000]) {
      final bmp = _bmp(depth: 24, headerSize: 56, compression: 3);
      _set32(bmp, 54, mask);
      expect(
        () => prepareUgoiraBmp(bmp, maxPixels: 2),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
