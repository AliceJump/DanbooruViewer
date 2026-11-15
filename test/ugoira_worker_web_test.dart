@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/media_save_service.dart';
import 'package:danbooru_viewer/media_save_types.dart';
import 'package:danbooru_viewer/network/network_errors.dart';
import 'package:danbooru_viewer/ugoira_codec.dart';
import 'package:danbooru_viewer/ugoira_conversion_web.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/browser_worker_assets.dart';

class _ControlledAssetBundle extends CachingAssetBundle {
  _ControlledAssetBundle(this.first, this.script);

  final Future<ByteData> first;
  final ByteData script;
  int loads = 0;

  @override
  Future<ByteData> load(String key) {
    expect(key, ugoiraWorkerAsset);
    return ++loads == 1 ? first : Future.value(script);
  }
}

Uint8List _animationZip({int frames = 2, int size = 4}) {
  final image = img.Image(width: size, height: size);
  for (final pixel in image) {
    pixel.setRgb(
      (pixel.x * 17 + pixel.y * 3) % 256,
      (pixel.y * 5) % 256,
      ((pixel.x ^ pixel.y) * 7) % 256,
    );
  }
  final png = img.encodePng(image);
  final archive = Archive();
  final metadata = <Map<String, Object>>[];
  for (var i = 0; i < frames; i++) {
    final name = '${i.toString().padLeft(6, '0')}.png';
    archive.add(ArchiveFile.bytes(name, png));
    metadata.add({'file': name, 'delay': 100 + i * 10});
  }
  archive.add(
    ArchiveFile.bytes(
      'frame_data.json',
      utf8.encode(jsonEncode({'frames': metadata})),
    ),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useGeneratedBrowserWorkerAsset();

  test('worker returns the shared codec GIF without detaching input', () async {
    final bytes = _animationZip();
    final original = Uint8List.fromList(bytes);
    final converted = await convertUgoiraBytesToGif(bytes);
    expect(converted, orderedEquals(mergeUgoiraBytesToGifSync(original)));
    expect(bytes, orderedEquals(original));
    final decoded = img.decodeGif(converted)!;
    expect(decoded.frames.length, 2);
    expect(decoded.frames.map((frame) => frame.frameDuration), [100, 110]);
  });

  test(
    'real worker leaves browser timers running during conversion',
    () async {
      final bytes = _animationZip(frames: 48, size: 128);
      var ticksWhileConverting = 0;
      var finished = false;
      Timer? heartbeat;
      final converter = WebUgoiraConverter(
        onStarted: () {
          // This message is emitted inside the real worker immediately before
          // ZIP decoding. Count only events before its actual result arrives.
          heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
            if (!finished) ticksWhileConverting++;
          });
        },
      );
      try {
        final gif = await converter.convert(bytes);
        finished = true;
        expect(ascii.decode(gif.take(3).toList()), 'GIF');
        expect(ticksWhileConverting, greaterThan(0));
      } finally {
        finished = true;
        heartbeat?.cancel();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'running worker cancellation promptly releases the next task',
    () async {
      final token = NetworkCancelToken();
      var starts = 0;
      final cancellationTime = Stopwatch();
      final converter = WebUgoiraConverter(
        onStarted: () {
          starts++;
          if (starts == 1) {
            Timer.run(() {
              cancellationTime.start();
              token.cancel();
            });
          }
        },
      );
      final failed = expectLater(
        converter.convert(
          _animationZip(frames: 48, size: 128),
          cancelToken: token,
        ),
        throwsA(isA<NetworkCancelledException>()),
      );
      final next = converter.convert(_animationZip());
      await failed;
      cancellationTime.stop();
      expect(cancellationTime.elapsed, lessThan(const Duration(seconds: 3)));
      expect(ascii.decode((await next).take(3).toList()), 'GIF');
      expect(starts, 2);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'cancelled asset load cannot create a late worker and can retry',
    () async {
      final script = await rootBundle.load(ugoiraWorkerAsset);
      final loading = Completer<ByteData>();
      final bundle = _ControlledAssetBundle(loading.future, script);
      var starts = 0;
      final converter = WebUgoiraConverter(
        assetBundle: bundle,
        onStarted: () => starts++,
      );
      final token = NetworkCancelToken();
      final failed = expectLater(
        converter.convert(_animationZip(), cancelToken: token),
        throwsA(isA<NetworkCancelledException>()),
      );
      token.cancel();
      await failed;
      loading.complete(script);
      expect(
        ascii.decode(
          (await converter.convert(_animationZip())).take(3).toList(),
        ),
        'GIF',
      );
      expect(starts, 1);
      expect(bundle.loads, 2);
    },
  );

  test(
    'asset timeout releases the queue without a synchronous fallback',
    () async {
      final converter = WebUgoiraConverter(
        loadScript: () => Completer<String>().future,
        timeout: const Duration(milliseconds: 20),
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          converter.convert(_animationZip()),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('超时'),
            ),
          ),
        );
      }
    },
  );

  test(
    'missing asset can retry and worker script failures stay explicit',
    () async {
      final script = await rootBundle.load(ugoiraWorkerAsset);
      final missing = Completer<ByteData>();
      final bundle = _ControlledAssetBundle(missing.future, script);
      final converter = WebUgoiraConverter(assetBundle: bundle);
      final failure = expectLater(
        converter.convert(_animationZip()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('无法加载'),
          ),
        ),
      );
      missing.completeError(StateError('missing asset'));
      await failure;
      expect(
        ascii.decode(
          (await converter.convert(_animationZip())).take(3).toList(),
        ),
        'GIF',
      );
      expect(bundle.loads, 2);
      final broken = WebUgoiraConverter(
        loadScript: () async => 'throw new Error("worker boot failure");',
      );
      await expectLater(
        broken.convert(_animationZip()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('无法加载'),
          ),
        ),
      );
    },
  );

  test(
    'worker preserves format errors and saving uses the same worker path',
    () async {
      await expectLater(
        convertUgoiraBytesToGif(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
      final zip = _animationZip();
      final saved = await convertUgoiraForSave(
        MediaSaveInput(Stream.value(zip), length: zip.length),
      );
      final gif = await saved.stream.expand((chunk) => chunk).toList();
      expect(saved.length, gif.length);
      expect(gif, orderedEquals(mergeUgoiraBytesToGifSync(zip)));
      await expectLater(
        convertUgoiraForSave(
          MediaSaveInput(Stream.value(zip), length: zip.length),
          cancelToken: NetworkCancelToken()..cancel(),
        ),
        throwsA(isA<NetworkCancelledException>()),
      );
    },
  );
}
