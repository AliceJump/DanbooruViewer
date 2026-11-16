import 'dart:convert';
import 'dart:typed_data';

import 'package:danbooru_viewer/ugoira_jpeg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// Ordinary tiny fixtures generated with Pillow 13.0, quality=90. The RGB
// fixture uses progressive=True/subsampling=2; the other two use defaults.
const _progressive =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wgARCAALABMDASIAAhEBAxEB/8QAFwAAAwEAAAAAAAAAAAAAAAAAAAUGB//EABUBAQEAAAAAAAAAAAAAAAAAAAYF/9oADAMBAAIQAxAAAAGQe1b1KfjTSCU+/8QAGhAAAgMBAQAAAAAAAAAAAAAAAAMBAgURIf/aAAgBAQABBQJOWJyyMvxK6iV1IXXn/8QAGREAAwADAAAAAAAAAAAAAAAAAAMFAREh/9oACAEDAQE/AZdVnDFVmj//xAAYEQACAwAAAAAAAAAAAAAAAAAAAgMFFf/aAAgBAgEBPwGexc0HP//EABUQAQEAAAAAAAAAAAAAAAAAAAAx/9oACAEBAAY/AoiIiP/EABcQAQEBAQAAAAAAAAAAAAAAAAAhMRH/2gAIAQEAAT8hwcGBglBLgS//2gAMAwEAAgADAAAAEPAP/8QAFhEBAQEAAAAAAAAAAAAAAAAAABFR/9oACAEDAQE/ENpCf//EABcRAQADAAAAAAAAAAAAAAAAAAABESH/2gAIAQIBAT8Q0pvf/8QAGRAAAgMBAAAAAAAAAAAAAAAAAPEQUWGB/9oACAEBAAE/EFAoOQqWGM4H/9k=';
const _grayscale =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wAALCAAJABEBAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/APlL4N/D/wD1H7v07V91fBv4f/6j936dq+hP+Ff/APTP9K/OX4N/8sPwr7q+Df8Ayw/CvoSv/9k=';
const _cmyk =
    '/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAFAgAAgADBEMRAE0RAFkRAEsRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAA4EQwBNAFkASwAAPwDo/wBor/kt3jD/AK/m/wDQRX0D/wAJ94n/AOhj1f8A8Dpf/iq+za/QOv/Z';

Uint8List _segment(int marker, List<int> payload) => Uint8List.fromList([
  0xff,
  marker,
  (payload.length + 2) >> 8,
  (payload.length + 2) & 255,
  ...payload,
]);

Uint8List _insertMetadata(Uint8List jpeg, int marker, List<int> payload) =>
    Uint8List.fromList([
      ...jpeg.take(2),
      ..._segment(marker, payload),
      ...jpeg.skip(2),
    ]);

int _headerOffset(Uint8List jpeg, int marker) {
  var offset = 2;
  while (offset + 4 <= jpeg.length) {
    if (jpeg[offset] != 0xff) throw StateError('fixture header boundary');
    final type = jpeg[offset + 1];
    if (type == marker) return offset;
    if (type == 0xda || type == 0xd9) break;
    offset += 2 + jpeg[offset + 2] * 256 + jpeg[offset + 3];
  }
  throw StateError('fixture marker $marker missing');
}

Uint8List _editHeader(
  Uint8List jpeg,
  int marker,
  void Function(List<int> payload) edit,
) {
  final offset = _headerOffset(jpeg, marker);
  final length = jpeg[offset + 2] * 256 + jpeg[offset + 3];
  final payload = jpeg.sublist(offset + 4, offset + 2 + length).toList();
  edit(payload);
  return Uint8List.fromList([
    ...jpeg.take(offset),
    ..._segment(marker, payload),
    ...jpeg.skip(offset + 2 + length),
  ]);
}

Uint8List _rgb({img.JpegChroma chroma = img.JpegChroma.yuv444}) {
  final frame = img.Image(width: 17, height: 17);
  for (final pixel in frame) {
    pixel.setRgb(pixel.x * 12, pixel.y * 12, 140);
  }
  return img.encodeJpg(frame, quality: 90, chroma: chroma);
}

({Uint8List bytes, int width, int height}) _prepare(
  Uint8List jpeg, {
  int maxPixels = 1024,
  int maxCoefficientBytes = 16384,
}) => prepareUgoiraJpeg(
  jpeg,
  maxPixels: maxPixels,
  maxCoefficientBytes: maxCoefficientBytes,
);

Matcher _fails(String reason) => throwsA(
  isA<FormatException>().having(
    (error) => error.message,
    'reason',
    contains(reason),
  ),
);

Uint8List _restartJpeg({bool fill = false}) {
  // Two 8x8 grayscale blocks: DC=0, EOB, then six padding bits. All
  // allocations remain tiny even if a test explicitly decodes this fixture.
  final huffman = [1, ...List<int>.filled(15, 0), 0];
  return Uint8List.fromList([
    0xff,
    0xd8,
    ..._segment(0xdb, [0, ...List<int>.filled(64, 1)]),
    ..._segment(0xc0, [8, 0, 8, 0, 16, 1, 1, 0x11, 0]),
    ..._segment(0xc4, [0, ...huffman, 0x10, ...huffman]),
    ..._segment(0xdd, [0, 1]),
    ..._segment(0xda, [1, 1, 0, 0, 63, 0]),
    0x3f,
    0xff,
    if (fill) 0xff,
    0xd0,
    0x3f,
    0xff,
    0xd9,
  ]);
}

Uint8List _orientation(int value, {Endian endian = Endian.big}) {
  final payload = Uint8List(32)..setRange(0, 6, [69, 120, 105, 102, 0, 0]);
  final tiff = ByteData.sublistView(payload, 6);
  tiff
    ..setUint16(0, endian == Endian.big ? 0x4d4d : 0x4949)
    ..setUint16(2, 42, endian)
    ..setUint32(4, 8, endian)
    ..setUint16(8, 1, endian)
    ..setUint16(10, 0x0112, endian)
    ..setUint16(12, 3, endian)
    ..setUint32(14, 1, endian)
    ..setUint16(18, value, endian);
  return payload;
}

void main() {
  for (final chroma in img.JpegChroma.values) {
    test('baseline $chroma preserves decoded pixels after preparation', () {
      final original = _rgb(chroma: chroma);
      final prepared = _prepare(original);
      final expected = img.JpegDecoder().decode(original)!;
      final actual = img.JpegDecoder().decode(prepared.bytes)!;
      expect((prepared.width, prepared.height), (17, 17));
      expect((actual.width, actual.height), (17, 17));
      expect(actual.getBytes(), expected.getBytes());
      expect(_prepare(prepared.bytes).bytes, prepared.bytes);
    });
  }

  for (final fixture in [
    ('progressive RGB', _progressive, 19, 11),
    ('grayscale with stuffed entropy bytes', _grayscale, 17, 9),
    ('Adobe CMYK', _cmyk, 3, 2),
  ]) {
    test('${fixture.$1} retains dimensions and real colors', () {
      final original = base64Decode(fixture.$2);
      final prepared = _prepare(original);
      final decoded = img.JpegDecoder().decode(prepared.bytes)!;
      expect((prepared.width, prepared.height), (fixture.$3, fixture.$4));
      expect(
        decoded.getBytes(),
        img.JpegDecoder().decode(original)!.getBytes(),
      );
    });
  }

  test('SOF1 extended sequential 8-bit JPEG is retained', () {
    final jpeg = _rgb();
    jpeg[_headerOffset(jpeg, 0xc0) + 1] = 0xc1;
    final prepared = _prepare(jpeg);
    expect(img.JpegDecoder().decode(prepared.bytes)!.width, 17);
  });

  test('coefficient budget includes MCU padding, not just visible pixels', () {
    final jpeg = _rgb(chroma: img.JpegChroma.yuv420);
    // 17x17 at 4:2:0 => 2x2 MCUs, 6 blocks/MCU, 64 Int32s/block.
    const actualBytes = 2 * 2 * 6 * 64 * 4;
    expect(
      () => _prepare(jpeg, maxCoefficientBytes: actualBytes - 1),
      _fails('系数块内存'),
    );
    final prepared = _prepare(jpeg, maxCoefficientBytes: actualBytes);
    expect(img.JpegDecoder().decode(prepared.bytes)!.height, 17);
  });

  test('grayscale coefficient and remaining pixel budgets are independent', () {
    final jpeg = base64Decode(_grayscale);
    expect(() => _prepare(jpeg, maxPixels: 152), _fails('尺寸'));
    expect(
      () => _prepare(jpeg, maxCoefficientBytes: 3 * 2 * 64 * 4 - 1),
      _fails('系数块内存'),
    );
    expect(_prepare(jpeg, maxPixels: 153).width, 17);
  });

  test('oversized SOF is rejected without invoking any decoder', () {
    final jpeg = _editHeader(_rgb(), 0xc0, (payload) {
      payload.setRange(1, 5, [255, 255, 255, 255]);
    });
    expect(jpeg.length, lessThan(2048));
    expect(() => _prepare(jpeg, maxPixels: 16 * 1024 * 1024), _fails('尺寸'));
  });

  for (final edit in <(String, void Function(List<int>))>[
    ('12-bit precision', (p) => p[0] = 12),
    (
      'zero height',
      (p) {
        p[1] = 0;
        p[2] = 0;
      },
    ),
    ('two components', (p) => p[5] = 2),
    ('duplicate component IDs', (p) => p[9] = p[6]),
    ('zero horizontal sampling', (p) => p[7] = 0x01),
    ('oversized vertical sampling', (p) => p[7] = 0x15),
    ('unsupported 3:1 sampling', (p) => p[7] = 0x31),
    ('invalid quantization selector', (p) => p[8] = 4),
    ('extra SOF bytes', (p) => p.add(0)),
    ('truncated component list', (p) => p.removeLast()),
  ]) {
    test('${edit.$1} fails in bounded SOF preparation', () {
      final jpeg = _editHeader(_rgb(), 0xc0, edit.$2);
      expect(() => _prepare(jpeg), throwsFormatException);
    });
  }

  test('a second SOF after restarted entropy is rejected before decode', () {
    final jpeg = _restartJpeg();
    final second = _segment(0xc0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]);
    final ambiguous = Uint8List.fromList([
      ...jpeg.take(jpeg.length - 2),
      ...second,
      0xff,
      0xd9,
    ]);
    expect(ambiguous.length, lessThan(256));
    // readInfo's RST-as-length path differs from read's entropy parser; the
    // preflight must inspect beyond the first scan, not trust either header.
    expect(() => _prepare(ambiguous), _fails('多个帧头'));
  });

  test('ordinary restart markers and their fill bytes decode consistently', () {
    for (final fill in [false, true]) {
      final prepared = _prepare(_restartJpeg(fill: fill));
      final image = img.JpegDecoder().decode(prepared.bytes)!;
      expect((image.width, image.height), (16, 8));
      expect(
        image.every(
          (pixel) => pixel.r == 128 && pixel.g == 128 && pixel.b == 128,
        ),
        isTrue,
      );
    }
  });

  test('APP and COM payloads cannot supply decoder-visible frame headers', () {
    final original = _rgb();
    final payload = [
      ...'untrusted metadata'.codeUnits,
      ..._segment(0xc0, [8, 0, 1, 0, 1, 1, 1, 0x11, 0]),
    ];
    var jpeg = _insertMetadata(original, 0xe1, payload);
    jpeg = _insertMetadata(jpeg, 0xfe, payload);
    final prepared = _prepare(jpeg);
    expect(prepared.bytes.length, lessThan(original.length));
    expect(
      img.JpegDecoder().decode(prepared.bytes)!.getBytes(),
      img.JpegDecoder().decode(original)!.getBytes(),
    );
  });

  for (final endian in [Endian.big, Endian.little]) {
    test(
      'bounded ${endian == Endian.big ? 'big' : 'little'}-endian EXIF orientation retains actual rotation',
      () {
        final original = base64Decode(_grayscale);
        final source = img.JpegDecoder().decode(original)!;
        final metadata = _orientation(6, endian: endian);
        // This unused next-IFD pointer is intentionally never followed or copied.
        ByteData.sublistView(metadata).setUint32(28, 0xffffffff, endian);
        final prepared = _prepare(_insertMetadata(original, 0xe1, metadata));
        final actual = img.JpegDecoder().decode(prepared.bytes)!;
        expect((prepared.width, prepared.height), (17, 9));
        expect((actual.width, actual.height), (9, 17));
        for (final pixel in source) {
          expect(
            actual.getPixel(source.height - 1 - pixel.y, pixel.x).r,
            pixel.r,
          );
        }
        // A fixed 32-byte EXIF payload, without the original external pointer.
        final app1 = _headerOffset(prepared.bytes, 0xe1);
        expect(prepared.bytes[app1 + 2] * 256 + prepared.bytes[app1 + 3], 34);
        expect(prepared.bytes.sublist(app1 + 32, app1 + 36), [0, 0, 0, 0]);
      },
    );
  }

  test('invalid or indirect EXIF orientation is ignored without traversal', () {
    final original = base64Decode(_grayscale);
    for (final mutate in <void Function(ByteData)>[
      (view) => view.setUint32(10, 0xffffffff),
      (view) => view.setUint16(14, 257),
      (view) => view.setUint32(20, 100000),
      (view) => view.setUint16(24, 9),
    ]) {
      final metadata = _orientation(6);
      mutate(ByteData.sublistView(metadata));
      final prepared = _prepare(_insertMetadata(original, 0xe1, metadata));
      expect(
        (img.JpegDecoder().decode(prepared.bytes)!.width, prepared.width),
        (17, 17),
      );
    }
  });

  test('truncation, trailing frames and unknown structural markers fail', () {
    final jpeg = _rgb();
    final unknown = _insertMetadata(jpeg, 0xdc, [0, 17]);
    for (final bytes in [
      Uint8List.fromList(jpeg.take(jpeg.length - 2).toList()),
      Uint8List.fromList([...jpeg, 0xff, 0xd8]),
      unknown,
    ]) {
      expect(() => _prepare(bytes), throwsFormatException);
    }
  });

  test('coding tables and SOS selectors are checked within segment bounds', () {
    final jpeg = _rgb();
    for (final modified in [
      _editHeader(jpeg, 0xdb, (p) => p.removeLast()),
      _editHeader(jpeg, 0xc4, (p) => p[1] = 255),
      _editHeader(jpeg, 0xda, (p) => p[1] = 255),
      _editHeader(jpeg, 0xda, (p) => p[2] = 0x44),
      _editHeader(jpeg, 0xda, (p) => p[p.length - 2] = 64),
    ]) {
      expect(() => _prepare(modified), throwsFormatException);
    }
  });
}
