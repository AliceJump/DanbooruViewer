import 'dart:io';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/media_save_platform_io.dart';
import 'package:danbooru_viewer/media_save_service.dart';
import 'package:danbooru_viewer/media_save_types.dart';
import 'package:danbooru_viewer/media_types.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.directory);
  final Directory directory;
  @override
  Future<String?> getDownloadsPath() async => directory.path;
  @override
  Future<String?> getTemporaryPath() async => directory.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'names and media kind ignore signed queries and do not escape directories',
    () {
      const url = 'https://example.test/file.MP4?signature=secret&format=jpg';
      expect(isVideoUrl(url), isTrue);
      expect(mediaSaveFileName(url, postId: 42), 'danbooru_42_file.MP4');
      expect(
        mediaSaveFileName('https://example.test/a.zip?key=secret'),
        'danbooru_a.gif',
      );
      expect(
        mediaSaveFileName('https://example.test/../../CON.mov'),
        'danbooru_CON.mov',
      );
      expect(mediaSaveFileName(r'C:\cache\image.gif'), 'danbooru_image.gif');
    },
  );

  test(
    'invalid remote schemes and pre-cancelled saves never open a destination',
    () async {
      for (final source in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'https://user:pw@example.test/a.jpg',
      ]) {
        await expectLater(
          saveMediaResource(source),
          throwsA(isA<MediaSaveException>()),
        );
      }
      final token = NetworkCancelToken()..cancel();
      await expectLater(
        saveMediaResource('https://example.test/a.jpg', cancelToken: token),
        throwsA(isA<NetworkCancelledException>()),
      );
    },
  );

  test('save errors retain storage and format diagnostics', () {
    expect(formatMediaSaveError(const MediaSaveException('目录不可写')), '目录不可写');
    expect(formatMediaSaveError(const FormatException('动图尺寸过大')), '动图尺寸过大');
    expect(formatMediaSaveError(const NetworkCancelledException()), '请求已取消。');
    expect(
      formatMediaSaveError(StateError('private local path')),
      isNot(contains('private local path')),
    );
  });

  group('desktop files', () {
    late Directory temporary;
    late PathProviderPlatform previous;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('danbooru_save_test_');
      previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TemporaryPaths(temporary);
    });
    tearDown(() async {
      PathProviderPlatform.instance = previous;
      await temporary.delete(recursive: true);
    });

    test(
      'a local Ugoira ZIP is converted before publishing a GIF name',
      () async {
        final frame = img.Image(width: 8, height: 6);
        img.fill(frame, color: img.ColorRgb8(90, 20, 50));
        final archive = Archive()
          ..add(ArchiveFile.bytes('000000.png', img.encodePng(frame)));
        final source = File('${temporary.path}/animation.zip');
        final zipped = ZipEncoder().encode(archive);
        await source.writeAsBytes(zipped);
        final result = await saveMediaResource(source.path, postId: 123);
        expect(result.destination, contains('danbooru_123_animation_'));
        expect(result.destination, endsWith('.gif'));
        expect(result.isVideo, isFalse);
        final saved = await File(result.destination).readAsBytes();
        expect(String.fromCharCodes(saved.take(3)), 'GIF');
        final decoded = img.decodeGif(saved)!;
        expect(decoded.width, 8);
        expect(decoded.height, 6);
        expect(await source.readAsBytes(), zipped);
      },
      skip: !(Platform.isWindows || Platform.isLinux),
    );

    test(
      'CORS-hidden encoding does not reject a complete decoded browser download',
      () async {
        final decoded = List<int>.filled(1024, 120);
        final compressed = gzip.encode(decoded);
        expect(compressed.length, lessThan(decoded.length));
        final response = http.StreamedResponse(
          Stream.value(decoded),
          200,
          contentLength: compressed.length,
          // These are the response headers visible to Fetch after CORS
          // filtering: Content-Length is exposed, Content-Encoding is not.
          headers: {'content-length': '${compressed.length}'},
        );
        final progressTotals = <int?>[];
        final result = await saveMediaToPlatform(
          fileName: 'compressed.jpg',
          isVideo: false,
          openSource: () async =>
              mediaSaveInputFromHttp(response, browserManaged: true),
          onProgress: (_, total) => progressTotals.add(total),
        );
        expect(await File(result.destination).readAsBytes(), decoded);
        expect(progressTotals, [null]);
      },
      skip: !(Platform.isWindows || Platform.isLinux),
    );

    test(
      'streams files with correct suffix, progress and unique names',
      () async {
        final progress = <int>[];
        Future<MediaSaveInput> input() async => MediaSaveInput(
          Stream.fromIterable([
            [1, 2],
            [3, 4, 5],
          ]),
          length: 5,
        );
        final first = await saveMediaToPlatform(
          fileName: 'post.webm',
          isVideo: true,
          openSource: input,
          onProgress: (received, total) {
            expect(total, 5);
            progress.add(received);
          },
        );
        final second = await saveMediaToPlatform(
          fileName: 'post.webm',
          isVideo: true,
          openSource: input,
        );
        expect(first.isVideo, isTrue);
        expect(first.destination, endsWith('.webm'));
        expect(await File(first.destination).readAsBytes(), [1, 2, 3, 4, 5]);
        expect(second.destination, isNot(first.destination));
        expect(progress, [2, 5]);
        expect(
          await temporary
              .list(recursive: true)
              .where(
                (entry) =>
                    entry.path.contains('danbooru_save_') && entry is File,
              )
              .length,
          2,
        );
      },
      skip: !(Platform.isWindows || Platform.isLinux),
    );

    test(
      'cancellation removes partial files and never publishes a completed name',
      () async {
        final token = NetworkCancelToken();
        await expectLater(
          saveMediaToPlatform(
            fileName: 'post.mp4',
            isVideo: true,
            cancelToken: token,
            openSource: () async => MediaSaveInput(
              Stream.fromIterable([
                [1, 2],
                [3, 4],
              ]),
              length: 4,
            ),
            onProgress: (_, _) => token.cancel(),
          ),
          throwsA(isA<NetworkCancelledException>()),
        );
        expect(
          await temporary
              .list(recursive: true)
              .where((entry) => entry is File)
              .toList(),
          isEmpty,
        );
        expect(
          await temporary
              .list(recursive: true)
              .where(
                (entry) => entry.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('danbooru_save_'),
              )
              .toList(),
          isEmpty,
        );
      },
      skip: !(Platform.isWindows || Platform.isLinux),
    );

    test(
      'truncated or empty responses leave no exported file',
      () async {
        for (final bytes in [
          <int>[],
          [1, 2],
        ]) {
          await expectLater(
            saveMediaToPlatform(
              fileName: 'post.jpg',
              isVideo: false,
              openSource: () async =>
                  MediaSaveInput(Stream.value(bytes), length: 10),
            ),
            throwsA(isA<MediaSaveException>()),
          );
        }
        expect(
          await temporary
              .list(recursive: true)
              .where((entry) => entry is File)
              .toList(),
          isEmpty,
        );
      },
      skip: !(Platform.isWindows || Platform.isLinux),
    );
  });
}
