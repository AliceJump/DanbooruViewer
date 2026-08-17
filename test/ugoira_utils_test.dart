import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/ugoira_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('mergeUgoiraToGifSync merges frames with per-frame delays', () {
    final dir = Directory.systemTemp.createTempSync('ugoira_test');
    try {
      final frames = <List<int>>[];
      for (var i = 0; i < 3; i++) {
        final image = img.Image(width: 64, height: 64);
        img.fill(image, color: img.ColorRgb8(40 * i, 20, 200 - 40 * i));
        frames.add(img.encodePng(image));
      }

      final archive = Archive()
        ..add(ArchiveFile.bytes('000000.png', frames[0]))
        ..add(ArchiveFile.bytes('000001.png', frames[1]))
        ..add(ArchiveFile.bytes('000002.png', frames[2]))
        ..add(
          ArchiveFile.string(
            'frame_data.json',
            json.encode({
              'frames': [
                {'file': '000000.png', 'delay': 60},
                {'file': '000001.png', 'delay': 120},
                {'file': '000002.png', 'delay': 90},
              ],
              'mime_type': 'image/png',
            }),
          ),
        );
      final zipPath = '${dir.path}${Platform.pathSeparator}test.zip';
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

      final gif = mergeUgoiraToGifSync(zipPath);
      final decoded = img.decodeGif(gif);
      expect(decoded, isNotNull);
      final anim = decoded!;
      expect(anim.frames.length, 3);
      expect(anim.frames[0].frameDuration, 60);
      expect(anim.frames[1].frameDuration, 120);
      expect(anim.frames[2].frameDuration, 90);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('mergeUgoiraToGifSync falls back to natural sort without frame_data',
      () {
    final dir = Directory.systemTemp.createTempSync('ugoira_test');
    try {
      final image = img.Image(width: 32, height: 32);
      img.fill(image, color: img.ColorRgb8(10, 10, 10));
      final png = img.encodePng(image);

      final archive = Archive()
        ..add(ArchiveFile.bytes('2.png', png))
        ..add(ArchiveFile.bytes('10.png', png))
        ..add(ArchiveFile.bytes('1.png', png));
      final zipPath = '${dir.path}${Platform.pathSeparator}test2.zip';
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

      final gif = mergeUgoiraToGifSync(zipPath);
      final decoded = img.decodeGif(gif);
      expect(decoded, isNotNull);
      final anim = decoded!;
      expect(anim.frames.length, 3);
      // Natural sort puts 1, 2, 10 (not 1, 10, 2).
      expect(anim.frames[0].frameDuration, 60);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('isUgoiraUrl detects zip URLs', () {
    expect(isUgoiraUrl('https://cdn.donmai.us/original/a/b/123.zip'), isTrue);
    expect(
      isUgoiraUrl('https://cdn.donmai.us/original/a/b/123.ZIP'),
      isTrue,
    );
    expect(isUgoiraUrl('https://cdn.donmai.us/original/a/b/123.png'), isFalse);
    expect(isUgoiraUrl('https://cdn.donmai.us/original/a/b/123.mp4'), isFalse);
    expect(isUgoiraUrl(null), isFalse);
  });
}