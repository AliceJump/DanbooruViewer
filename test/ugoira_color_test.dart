import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/ugoira_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _zip(String name, Uint8List bytes) => Uint8List.fromList(
  ZipEncoder().encode(Archive()..add(ArchiveFile.bytes(name, bytes))),
);

img.Image _redFrame(int width) {
  final frame = img.Image(width: width, height: 1, numChannels: 4);
  for (final pixel in frame) {
    pixel.setRgba(255, 0, 0, 255);
  }
  return frame;
}

void _expectRedGif(Uint8List gif, int width) {
  final image = img.decodeGif(gif)!;
  expect((image.width, image.height), (width, 1));
  for (final pixel in image) {
    expect(pixel.r, greaterThan(200));
    expect(pixel.g, lessThan(40));
    expect(pixel.b, lessThan(40));
  }
}

void main() {
  final frame = _redFrame(2);
  final formats = {
    '000.png': img.encodePng(frame),
    '000.jpg': img.encodeJpg(frame),
    '000.bmp': img.encodeBmp(frame),
    // Independent libwebp fixture shared with the browser worker regression.
    '000.webp': base64Decode(
      'UklGRhwAAABXRUJQVlA4TA8AAAAvAQAAAAcQ/Y/+ByKi/wEA',
    ),
  };
  for (final entry in formats.entries) {
    test('tiny ${entry.key} retains color through actual GIF conversion', () {
      _expectRedGif(mergeUgoiraBytesToGifSync(_zip(entry.key, entry.value)), 2);
    });
  }

  test('one-pixel and boundary-sized frames all train a color palette', () {
    for (final width in [1, 9, 10, 16]) {
      _expectRedGif(
        mergeUgoiraBytesToGifSync(
          _zip('000.png', img.encodePng(_redFrame(width))),
        ),
        width,
      );
    }
  });
}
