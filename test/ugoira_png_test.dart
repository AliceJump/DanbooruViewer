import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/ugoira_codec.dart';
import 'package:danbooru_viewer/ugoira_png.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _chunk(String type, List<int> payload) {
  final bytes = Uint8List(payload.length + 12);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, payload.length);
  bytes.setRange(4, 8, type.codeUnits);
  bytes.setRange(8, bytes.length - 4, payload);
  view.setUint32(
    bytes.length - 4,
    getCrc32(bytes.sublist(4, bytes.length - 4)),
  );
  return bytes;
}

Uint8List _png({
  int width = 1,
  int height = 1,
  int depth = 8,
  int color = 2,
  int interlace = 0,
  required List<int> raw,
  List<int>? compressed,
  bool splitIdat = false,
  List<Uint8List> metadata = const [],
}) {
  final header = Uint8List(13);
  ByteData.sublistView(header)
    ..setUint32(0, width)
    ..setUint32(4, height);
  header[8] = depth;
  header[9] = color;
  header[12] = interlace;
  final deflated = compressed ?? const ZLibEncoder().encode(raw);
  final bytes = BytesBuilder()
    ..add([137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_chunk('IHDR', header));
  if (color == 3) bytes.add(_chunk('PLTE', [0, 0, 0, 255, 255, 255]));
  for (final chunk in metadata) {
    bytes.add(chunk);
  }
  if (splitIdat) {
    bytes.add(_chunk('IDAT', []));
    for (final byte in deflated) {
      bytes.add(_chunk('IDAT', [byte]));
    }
  } else {
    bytes.add(_chunk('IDAT', deflated));
  }
  return (bytes..add(_chunk('IEND', []))).takeBytes();
}

Uint8List _zipPng(Uint8List png) => Uint8List.fromList(
  ZipEncoder().encode(Archive()..add(ArchiveFile.bytes('000.png', png))),
);

List<String> _chunkNames(Uint8List png) {
  final view = ByteData.sublistView(png);
  final result = <String>[];
  for (var offset = 8; offset < png.length;) {
    result.add(String.fromCharCodes(png.sublist(offset + 4, offset + 8)));
    offset += view.getUint32(offset) + 12;
  }
  return result;
}

void main() {
  test('tiny PNG cannot expand IDAT beyond its declared scanlines', () {
    final bytes = _zipPng(_png(raw: Uint8List(64 * 1024)));
    expect(bytes.length, lessThan(1024));
    expect(
      () => mergeUgoiraBytesToGifSync(bytes),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          contains('PNG'),
        ),
      ),
    );
  });

  test('ordinary RGB and split IDAT retain pixels before GIF quantization', () {
    for (final split in [false, true]) {
      final png = _png(
        width: 2,
        raw: [0, 255, 0, 0, 0, 255, 0],
        splitIdat: split,
      );
      final gif = img.decodeGif(mergeUgoiraBytesToGifSync(_zipPng(png)))!;
      expect(gif.width, 2);
      expect(gif.height, 1);
      final source = img.decodePng(
        prepareUgoiraPng(png, maxPixels: 2, maxOutputBytes: 7).bytes,
      )!;
      expect(source.getPixel(0, 0).r, 255);
      expect(source.getPixel(1, 0).g, 255);
    }
  });

  test('packed grayscale and indexed rows include byte padding', () {
    final fixtures = [
      _png(width: 9, height: 2, depth: 1, color: 0, raw: [0, 128, 0, 0, 0, 0]),
      _png(width: 5, depth: 2, color: 0, raw: [0, 0, 0]),
      _png(width: 3, depth: 4, color: 0, raw: [0, 0, 0]),
      _png(width: 3, depth: 2, color: 3, raw: [0, 16]),
    ];
    for (final png in fixtures) {
      final gif = mergeUgoiraBytesToGifSync(_zipPng(png));
      expect(img.decodeGif(gif), isNotNull);
    }
  });

  test('16-bit samples and alpha channels retain valid frames', () {
    final fixtures = [
      _png(depth: 16, color: 6, raw: [0, 255, 255, 0, 0, 0, 0, 255, 255]),
      _png(depth: 16, color: 0, raw: [0, 128, 128]),
      _png(color: 4, raw: [0, 128, 255]),
      _png(depth: 16, color: 4, raw: [0, 128, 128, 255, 255]),
    ];
    for (final png in fixtures) {
      expect(img.decodeGif(mergeUgoiraBytesToGifSync(_zipPng(png))), isNotNull);
    }
  });

  test('Adam7 handles empty passes and all seven nonempty passes', () {
    // 8x8 RGB: 64 pixels (192 bytes) + 15 pass scanline filters.
    final fixtures = [
      _png(interlace: 1, raw: [0, 255, 0, 0]),
      _png(width: 1, height: 8, interlace: 1, raw: Uint8List(32)),
      _png(width: 8, height: 8, interlace: 1, raw: Uint8List(207)),
    ];
    for (final png in fixtures) {
      expect(
        prepareUgoiraPng(png, maxPixels: 64, maxOutputBytes: 207).outputBytes,
        greaterThan(0),
      );
      expect(img.decodeGif(mergeUgoiraBytesToGifSync(_zipPng(png))), isNotNull);
    }
  });

  test('valid output larger than the 32 KiB history still decodes', () {
    final png = _png(width: 128, height: 128, raw: Uint8List(128 * 385));
    expect(
      prepareUgoiraPng(
        png,
        maxPixels: 16384,
        maxOutputBytes: 128 * 385,
      ).outputBytes,
      128 * 385,
    );
    final gif = img.decodeGif(mergeUgoiraBytesToGifSync(_zipPng(png)))!;
    expect((gif.width, gif.height), (128, 128));
  });

  test('the remaining animation output budget is applied before inflate', () {
    final png = _png(raw: [0, 255, 0, 0]);
    expect(
      prepareUgoiraPng(png, maxPixels: 1, maxOutputBytes: 4).outputBytes,
      4,
    );
    expect(
      () => prepareUgoiraPng(png, maxPixels: 1, maxOutputBytes: 3),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          contains('累计解压'),
        ),
      ),
    );
  });

  test('concatenated zlib streams cannot bypass scanline output limits', () {
    final png = _png(
      raw: [],
      compressed: [
        ...const ZLibEncoder().encode([0, 255, 0, 0]),
        ...const ZLibEncoder().encode(Uint8List(64 * 1024)),
      ],
    );
    expect(
      () => mergeUgoiraBytesToGifSync(_zipPng(png)),
      throwsA(isA<FormatException>()),
    );
  });

  test('wrong Adler checksum, short output and invalid zlib header fail', () {
    final original = Uint8List.fromList(
      const ZLibEncoder().encode([0, 0, 0, 0]),
    );
    final badAdler = Uint8List.fromList(original);
    badAdler[badAdler.length - 1] ^= 1;
    final badHeader = Uint8List.fromList(original)..[0] = 0;
    for (final compressed in [
      badAdler,
      badHeader,
      const ZLibEncoder().encode([0, 0, 0]),
    ]) {
      final png = _png(raw: [], compressed: compressed);
      expect(
        () => mergeUgoiraBytesToGifSync(_zipPng(png)),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test(
    'invalid PNG chunk CRC and truncated chunks fail before image decode',
    () {
      final valid = _png(raw: [0, 0, 0, 0]);
      final badCrc = Uint8List.fromList(valid)..[29] ^= 1;
      final badLength = Uint8List.fromList(valid);
      ByteData.sublistView(badLength).setUint32(33, 0xffffffff);
      for (final png in [
        badCrc,
        badLength,
        valid.sublist(0, valid.length - 1),
      ]) {
        expect(
          () => mergeUgoiraBytesToGifSync(_zipPng(png)),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  test('invalid dimensions and unsupported PNG header combinations fail', () {
    for (final png in [
      _png(width: 0, raw: [0]),
      _png(width: 0x7fffffff, raw: [0]),
      _png(depth: 16, color: 3, raw: [0, 0, 0]),
      _png(interlace: 2, raw: [0, 0, 0, 0]),
    ]) {
      expect(
        () => mergeUgoiraBytesToGifSync(_zipPng(png)),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('a PNG extension cannot select an unbudgeted TIFF decoder', () {
    final tiff = Uint8List.fromList(
      img.encodeTiff(img.Image(width: 1, height: 1)),
    );
    expect(
      () => mergeUgoiraBytesToGifSync(_zipPng(tiff)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          contains('只支持'),
        ),
      ),
    );
  });

  test('default APNG frame and ordinary metadata become a single image', () {
    final animation = Uint8List(8);
    ByteData.sublistView(animation).setUint32(0, 1);
    final frameControl = Uint8List(26);
    ByteData.sublistView(frameControl)
      ..setUint32(4, 1)
      ..setUint32(8, 1)
      ..setUint16(20, 1)
      ..setUint16(22, 10);
    final png = _png(
      raw: [0, 255, 0, 0],
      splitIdat: true,
      metadata: [
        _chunk('tEXt', 'Comment\u0000ordinary frame'.codeUnits),
        _chunk('pHYs', [0, 0, 0, 1, 0, 0, 0, 1, 1]),
        _chunk('acTL', animation),
        _chunk('fcTL', frameControl),
      ],
    );
    final prepared = prepareUgoiraPng(png, maxPixels: 1, maxOutputBytes: 4);
    expect(_chunkNames(prepared.bytes), ['IHDR', 'IDAT', 'IEND']);
    expect(prepared.outputBytes, 4);
    final frame = img.decodePng(prepared.bytes)!;
    expect(frame.getPixel(0, 0).r, 255);
    expect(frame.numFrames, 1);
    expect(img.decodeGif(mergeUgoiraBytesToGifSync(_zipPng(png))), isNotNull);
  });

  test('canonical image preserves palette transparency and gamma chunks', () {
    final gamma = Uint8List(4);
    ByteData.sublistView(gamma).setUint32(0, 100000);
    final png = _png(
      width: 2,
      depth: 1,
      color: 3,
      raw: [0, 64],
      metadata: [
        _chunk('tRNS', [0, 255]),
        _chunk('gAMA', gamma),
      ],
    );
    final prepared = prepareUgoiraPng(png, maxPixels: 2, maxOutputBytes: 2);
    expect(_chunkNames(prepared.bytes), [
      'IHDR',
      'gAMA',
      'PLTE',
      'tRNS',
      'IDAT',
      'IEND',
    ]);
    final frame = img.decodePng(prepared.bytes)!;
    expect(frame.getPixel(0, 0).a, 0);
    expect(frame.getPixel(1, 0).a, 255);
    expect(frame.getPixel(1, 0).r, 255);
  });

  test('retained color chunks must have valid fixed sizes', () {
    for (final metadata in [
      [_chunk('gAMA', [])],
      [
        _chunk('tRNS', [0]),
      ],
      [
        _chunk('PLTE', [0, 0]),
      ],
    ]) {
      final png = _png(raw: [0, 0, 0, 0], metadata: metadata);
      expect(
        () => prepareUgoiraPng(png, maxPixels: 1, maxOutputBytes: 4),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
