import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test('cache file names use a stable digest of the full URL', () {
    expect(
      ugoiraGifCacheFileName('https://example.test/a.zip'),
      'ugoira_a13fafbbf9d82f3de42004da13e538c8bccd21b3328514dbbcb845891f71167c.gif',
    );
    expect(
      ugoiraGifCacheFileName('https://example.test/a.zip?size=large'),
      isNot(ugoiraGifCacheFileName('https://example.test/a.zip')),
    );
  });

  test(
    'concurrent requests convert a GIF once and share the cached file',
    () async {
      final dir = await Directory.systemTemp.createTemp('ugoira_cache_test');
      try {
        final cached = File('${dir.path}${Platform.pathSeparator}shared.gif');
        final converted = Completer<Uint8List>();
        var conversions = 0;
        Future<Uint8List> convert() {
          conversions++;
          return converted.future;
        }

        final first = cacheUgoiraGifFile(cached, convert);
        final second = cacheUgoiraGifFile(cached, convert);
        await Future<void>.delayed(Duration.zero);
        expect(conversions, 1);
        expect(await cached.exists(), isFalse);

        converted.complete(Uint8List.fromList([71, 73, 70, 56, 57, 97]));
        expect((await first).path, cached.path);
        expect((await second).path, cached.path);
        expect(await cached.readAsBytes(), [71, 73, 70, 56, 57, 97]);
        expect((await cacheUgoiraGifFile(cached, convert)).path, cached.path);
        expect(conversions, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'failed cache publication removes temporary files and permits retry',
    () async {
      final dir = await Directory.systemTemp.createTemp('ugoira_cache_test');
      try {
        final cached = File('${dir.path}${Platform.pathSeparator}retry.gif');
        final occupied = Directory(cached.path)..createSync();
        var conversions = 0;
        Future<Uint8List> convert() async {
          conversions++;
          return Uint8List.fromList([71, 73, 70, 56, 57, 97]);
        }

        await expectLater(
          cacheUgoiraGifFile(cached, convert),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await dir.list().where((file) => file.path.endsWith('.tmp')).toList(),
          isEmpty,
        );

        await occupied.delete();
        expect((await cacheUgoiraGifFile(cached, convert)).path, cached.path);
        expect(conversions, 2);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test('zero-length cache entries are replaced', () async {
    final dir = await Directory.systemTemp.createTemp('ugoira_cache_test');
    try {
      final cached = File('${dir.path}${Platform.pathSeparator}empty.gif');
      await cached.writeAsBytes([]);
      await cacheUgoiraGifFile(
        cached,
        () async => Uint8List.fromList([71, 73, 70, 56, 57, 97]),
      );
      expect(await cached.length(), 6);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
