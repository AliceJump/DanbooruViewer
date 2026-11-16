import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:danbooru_viewer/ugoira_webp.dart';

// Independent libwebp fixtures, generated with Pillow Image.save(format='WEBP',
// quality=90). All are solid red; lossless1 is 1x1, the others are 2x1. alpha2
// uses RGBA (255, 0, 0, 128). Only lossless1/2 use lossless=True.
const _lossless1 = 'UklGRhwAAABXRUJQVlA4TA8AAAAvAAAAAAcQ/Y/+ByKi/wEA';
const _lossless2 = 'UklGRhwAAABXRUJQVlA4TA8AAAAvAQAAAAcQ/Y/+ByKi/wEA';
const _lossy2 =
    'UklGRkAAAABXRUJQVlA4IDQAAAAwAgCdASoCAAEAAMASJaACdLoB+AH4AARoAAD++iGX/3easNN39a3/9aOfron+tHP/WVgA';
const _alpha2 =
    'UklGRl4AAABXRUJQVlA4WAoAAAAQAAAAAQAAAAAAQUxQSAMAAAAAgIAAVlA4IDQAAAAwAgCdASoCAAEAAMASJaACdLoB+AH4AARoAAD++iGX/3easNN39a3/9aOfron+tHP/WVgA';
// Independent libwebp lossy 16x16 red, alternating alpha 192/128. Unlike
// alpha2, its ALPH chunk uses the compressed lossless image stream (method 1).
const _compressedAlpha16 =
    'UklGRnAAAABXRUJQVlA4WAoAAAAQAAAADwAADwAAQUxQSBUAAAABEBIQ103zTlQjgmCSptqOkfqcfwcAVlA4IDQAAAAwAgCdASoQABAAAMASJaACdLoB+AH4AARoAAD++iGX/3easNN39a3/9aOfron+tHP/WVgA';

void main() {
  test('lossless, lossy and alpha fixtures retain decoded pixels', () {
    for (final fixture in [_lossless1, _lossless2, _lossy2, _alpha2]) {
      final original = base64Decode(fixture);
      final expected = img.decodeWebP(original)!;
      final checked = prepareUgoiraWebp(original, maxPixels: 2);
      final actual = img.decodeWebP(checked.bytes)!;
      expect(checked.width, expected.width);
      expect(checked.height, expected.height);
      expect(actual.width, expected.width);
      expect(actual.height, expected.height);
      expect(actual.getBytes(), expected.getBytes());
    }
    final alpha = prepareUgoiraWebp(base64Decode(_alpha2), maxPixels: 2);
    expect(img.decodeWebP(alpha.bytes)!.getPixel(0, 0).a, 128);
  });

  test(
    'compressed alpha keeps its pixels through the lossless budget check',
    () {
      final original = base64Decode(_compressedAlpha16);
      final alphaChunk = _imageChunks(original).first;
      expect(String.fromCharCodes(alphaChunk.sublist(0, 4)), 'ALPH');
      expect(alphaChunk[8] & 3, 1);
      final checked = prepareUgoiraWebp(original, maxPixels: 256);
      final actual = img.decodeWebP(checked.bytes)!;
      expect(actual.getBytes(), img.decodeWebP(original)!.getBytes());
      expect((actual.width, actual.height), (16, 16));
      expect(actual.getPixel(0, 0).a, 192);
      expect(actual.getPixel(1, 0).a, 128);
    },
  );

  test(
    'animation returns the checked first frame with its real dimensions',
    () {
      final bytes = _animation(4, 2, [
        _frame(2, 1, _imageChunks(base64Decode(_lossless2))),
        _frame(1, 1, _imageChunks(base64Decode(_lossless1)), x: 2),
      ]);
      final original = img.WebPDecoder()..startDecode(bytes);
      final expected = original.decodeFrame(0)!;
      final checked = prepareUgoiraWebp(bytes, maxPixels: 8);
      final decoder = img.WebPDecoder();
      final info = decoder.startDecode(checked.bytes)!;
      final actual = decoder.decodeFrame(0)!;
      expect(info.hasAnimation, isFalse);
      expect((checked.width, checked.height), (2, 1));
      expect((actual.width, actual.height), (2, 1));
      expect(actual.getBytes(), expected.getBytes());
    },
  );

  test('animated lossy and alpha frames keep their first-frame pixels', () {
    for (final fixture in [_lossy2, _alpha2]) {
      final bytes = _animation(2, 1, [
        _frame(2, 1, _imageChunks(base64Decode(fixture))),
      ]);
      final decoder = img.WebPDecoder()..startDecode(bytes);
      final expected = decoder.decodeFrame(0)!;
      final checked = prepareUgoiraWebp(bytes, maxPixels: 2);
      expect(img.decodeWebP(checked.bytes)!.getBytes(), expected.getBytes());
    }
  });

  test(
    'small canvas cannot hide larger inner lossless allocation dimensions',
    () {
      // A small fixture covers the old outer/inner dimension mismatch. Both
      // the application preflight and image 4.13.1 must now reject it.
      final bytes = _animation(1, 1, [
        _frame(1, 1, _imageChunks(base64Decode(_lossless2))),
      ]);
      final decoder = img.WebPDecoder();
      final info = decoder.startDecode(bytes)!;
      expect((info.width, info.height), (1, 1));
      expect(() => decoder.decodeFrame(0), throwsA(isA<img.ImageException>()));
      expect(
        () => prepareUgoiraWebp(bytes, maxPixels: 2),
        throwsFormatException,
      );
    },
  );

  test('ANMF dimensions must also match the inner lossy dimensions', () {
    final bytes = _animation(2, 1, [
      _frame(1, 1, _imageChunks(base64Decode(_lossy2))),
    ]);
    expect(() => prepareUgoiraWebp(bytes, maxPixels: 2), throwsFormatException);
  });

  test(
    'both lossless image and compressed alpha check encoded group limits',
    () {
      // Six-byte prefix: a 1x1 meta image references group 4096, beyond the
      // encoded-group budget. No main Huffman tables or image payload follow;
      // the preflight must reject it before handing it to the real decoder.
      final prefix = base64Decode('hChE9D8A');
      final lossless = _riff([
        _chunk('VP8L', Uint8List.fromList([0x2f, 1, 0, 0, 0, ...prefix])),
      ]);
      final compressedAlpha = _riff([
        _extended(2, 1, flags: 0x10),
        _chunk('ALPH', Uint8List.fromList([1, ...prefix])),
        ..._imageChunks(base64Decode(_lossy2)),
      ]);
      for (final bytes in [lossless, compressedAlpha]) {
        expect(
          () => prepareUgoiraWebp(bytes, maxPixels: 2),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'reason',
              contains('编码表数量'),
            ),
          ),
        );
      }
    },
  );

  test('later frames are checked even though only the first is decoded', () {
    final bytes = _animation(2, 1, [
      _frame(1, 1, _imageChunks(base64Decode(_lossless1))),
      _frame(1, 1, _imageChunks(base64Decode(_lossless2))),
    ]);
    expect(() => prepareUgoiraWebp(bytes, maxPixels: 2), throwsFormatException);
  });

  test('pixel budget covers the canvas and actual bitstream headers', () {
    final ordinary = base64Decode(_lossless2);
    expect(
      () => prepareUgoiraWebp(ordinary, maxPixels: 1),
      throwsFormatException,
    );
    final animation = _animation(2, 2, [
      _frame(1, 1, _imageChunks(base64Decode(_lossless1))),
    ]);
    expect(
      () => prepareUgoiraWebp(animation, maxPixels: 2),
      throwsFormatException,
    );
    // Header only: the guard must reject this before any decoder runs.
    final huge = Uint8List.fromList([0x2f, 0xff, 0xff, 0xff, 0x0f]);
    expect(
      () => prepareUgoiraWebp(
        _riff([_chunk('VP8L', huge)]),
        maxPixels: 16 * 1024 * 1024,
      ),
      throwsFormatException,
    );
  });

  test('extended still-image canvas must agree with the bitstream', () {
    final bytes = _riff([
      _extended(1, 1),
      ..._imageChunks(base64Decode(_lossless2)),
    ]);
    expect(() => prepareUgoiraWebp(bytes, maxPixels: 2), throwsFormatException);
  });

  test('frame rectangles and reserved flags cannot escape the canvas', () {
    for (final frame in [
      _frame(1, 1, _imageChunks(base64Decode(_lossless1)), x: 2),
      _frame(1, 1, _imageChunks(base64Decode(_lossless1)), flags: 4),
    ]) {
      expect(
        () => prepareUgoiraWebp(_animation(1, 1, [frame]), maxPixels: 2),
        throwsFormatException,
      );
    }
  });

  test('nested animation and canvas chunks cannot select another stream', () {
    for (final nested in [
      _extended(1, 1),
      _chunk('ANIM', Uint8List(6)),
      _frame(1, 1, _imageChunks(base64Decode(_lossless1))),
    ]) {
      final bytes = _animation(1, 1, [
        _frame(1, 1, [nested, ..._imageChunks(base64Decode(_lossless1))]),
      ]);
      expect(
        () => prepareUgoiraWebp(bytes, maxPixels: 2),
        throwsFormatException,
      );
    }
  });

  test('duplicate image or animation headers are rejected', () {
    final image = _imageChunks(base64Decode(_lossless1)).single;
    for (final bytes in [
      _riff([image, image]),
      _animation(1, 1, [
        _frame(1, 1, [image, image]),
      ]),
      _riff([_extended(1, 1), _extended(1, 1), image]),
      _riff([
        _extended(1, 1, flags: 2),
        _chunk('ANIM', Uint8List(6)),
        _chunk('ANIM', Uint8List(6)),
        _frame(1, 1, [image]),
      ]),
    ]) {
      expect(
        () => prepareUgoiraWebp(bytes, maxPixels: 2),
        throwsFormatException,
      );
    }
  });

  test('RIFF and inner chunk lengths include padding and stay in bounds', () {
    final valid = base64Decode(_lossless1);
    final wrongRiff = Uint8List.fromList(valid);
    ByteData.sublistView(wrongRiff).setUint32(4, 4, Endian.little);
    final truncatedChunk = _riff([
      Uint8List.sublistView(valid, 12, valid.length - 1),
    ]);
    final inner = Uint8List.fromList(_imageChunks(valid).single);
    ByteData.sublistView(inner).setUint32(4, 1000, Endian.little);
    final badInner = _animation(1, 1, [
      _frame(1, 1, [inner]),
    ]);
    for (final bytes in [wrongRiff, truncatedChunk, badInner]) {
      expect(
        () => prepareUgoiraWebp(bytes, maxPixels: 2),
        throwsFormatException,
      );
    }
  });

  test('metadata cannot reach downstream image metadata parsers', () {
    final bytes = _riff([
      _extended(2, 1, flags: 0x0c),
      ..._imageChunks(base64Decode(_lossless2)),
      _chunk('EXIF', Uint8List.fromList([1, 2, 3])),
      _chunk('XMP ', Uint8List.fromList([4, 5, 6])),
    ]);
    final checked = prepareUgoiraWebp(bytes, maxPixels: 2);
    expect(_types(checked.bytes), ['VP8L']);
    expect(img.decodeWebP(checked.bytes)!.getPixel(0, 0).r, 255);
  });

  test(
    'VP8 scaling bits are rejected before the decoder sees raw dimensions',
    () {
      final bytes = base64Decode(_lossy2);
      ByteData.sublistView(bytes).setUint16(26, 0x4002, Endian.little);
      expect(
        () => prepareUgoiraWebp(bytes, maxPixels: 16 * 1024 * 1024),
        throwsFormatException,
      );
    },
  );

  test(
    'raw alpha length and flags are checked against the decoded dimensions',
    () {
      final image = _imageChunks(base64Decode(_lossy2)).single;
      for (final alpha in [
        Uint8List.fromList([0, 128]),
        Uint8List.fromList([0xc0, 128, 128]),
        Uint8List.fromList([2, 128, 128]),
      ]) {
        final bytes = _riff([
          _extended(2, 1, flags: 0x10),
          _chunk('ALPH', alpha),
          image,
        ]);
        expect(
          () => prepareUgoiraWebp(bytes, maxPixels: 2),
          throwsFormatException,
        );
      }
    },
  );
}

Uint8List _riff(List<Uint8List> chunks) {
  final content = BytesBuilder(copy: false)..add('WEBP'.codeUnits);
  for (final chunk in chunks) {
    content.add(chunk);
  }
  final header = Uint8List(8)..setRange(0, 4, 'RIFF'.codeUnits);
  ByteData.sublistView(header).setUint32(4, content.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header)
        ..add(content.takeBytes()))
      .takeBytes();
}

Uint8List _chunk(String type, Uint8List payload) {
  final bytes = Uint8List(8 + payload.length + (payload.length & 1));
  bytes.setRange(0, 4, type.codeUnits);
  ByteData.sublistView(bytes).setUint32(4, payload.length, Endian.little);
  bytes.setRange(8, 8 + payload.length, payload);
  return bytes;
}

Uint8List _extended(int width, int height, {int flags = 0}) {
  final bytes = Uint8List(10)..[0] = flags;
  _uint24(bytes, 4, width - 1);
  _uint24(bytes, 7, height - 1);
  return _chunk('VP8X', bytes);
}

Uint8List _animation(int width, int height, List<Uint8List> frames) => _riff([
  _extended(width, height, flags: 2),
  _chunk('ANIM', Uint8List(6)),
  ...frames,
]);

Uint8List _frame(
  int width,
  int height,
  List<Uint8List> chunks, {
  int x = 0,
  int y = 0,
  int flags = 0,
}) {
  final header = Uint8List(16);
  _uint24(header, 0, x ~/ 2);
  _uint24(header, 3, y ~/ 2);
  _uint24(header, 6, width - 1);
  _uint24(header, 9, height - 1);
  _uint24(header, 12, 60);
  header[15] = flags;
  final body = BytesBuilder(copy: false)..add(header);
  for (final chunk in chunks) {
    body.add(chunk);
  }
  return _chunk('ANMF', body.takeBytes());
}

List<Uint8List> _imageChunks(Uint8List bytes) {
  final chunks = <Uint8List>[];
  final data = ByteData.sublistView(bytes);
  for (var offset = 12; offset < bytes.length;) {
    final type = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final next = offset + 8 + size + (size & 1);
    if (type == 'VP8 ' || type == 'VP8L' || type == 'ALPH') {
      chunks.add(Uint8List.sublistView(bytes, offset, next));
    }
    offset = next;
  }
  return chunks;
}

List<String> _types(Uint8List bytes) {
  final types = <String>[];
  final data = ByteData.sublistView(bytes);
  for (var offset = 12; offset < bytes.length;) {
    types.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)));
    final size = data.getUint32(offset + 4, Endian.little);
    offset += 8 + size + (size & 1);
  }
  return types;
}

void _uint24(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 255;
  bytes[offset + 1] = (value >> 8) & 255;
  bytes[offset + 2] = (value >> 16) & 255;
}
