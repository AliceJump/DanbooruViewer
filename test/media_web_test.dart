import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:danbooru_viewer/ugoira_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _renderDecodedImage(
  WidgetTester tester,
  ImageProvider provider,
) async {
  // Browser decoding uses real engine futures. Wait outside the widget test's
  // fake clock, and finish the first frame before constructing the image tree.
  await tester.runAsync(() async {
    final firstFrame = Completer<ImageInfo>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (firstFrame.isCompleted) {
          info.dispose();
        } else {
          firstFrame.complete(info);
        }
      },
      onError: (Object error, StackTrace? stack) {
        if (!firstFrame.isCompleted) firstFrame.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    ImageInfo? decoded;
    try {
      decoded = await firstFrame.future.timeout(const Duration(seconds: 20));
      expect(decoded.image.width, 1);
      expect(decoded.image.height, 1);
    } finally {
      stream.removeListener(listener);
      decoded?.dispose();
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(width: 64, height: 64, child: Image(image: provider)),
    ),
  );
  await tester.pump();
  final rendered = tester.widget<RawImage>(find.byType(RawImage));
  expect(rendered.image, isNotNull);
  expect(rendered.image!.width, 1);
  expect(rendered.image!.height, 1);
  expect(tester.takeException(), isNull);
}

Future<void> _clearImages(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await AppCacheManager.instance.emptyCache();
  });
}

void main() {
  const browserOnly = !kIsWeb;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgmNbxHwAD1gIeATp91AAAAABJRU5ErkJggg==',
  );

  testWidgets(
    'browser cache renders bytes without FileImage or native IO',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const url = 'https://example.test/browser-cache.png';
      try {
        final provider = await tester.runAsync(() async {
          await AppCacheManager.instance.putFile(
            url,
            png,
            fileExtension: 'png',
          );
          return cachedMediaImageProvider(url);
        });
        expect(provider, isA<MemoryImage>());
        await _renderDecodedImage(tester, provider!);
        expect(supportsNativeMediaDrag, isFalse);
        expect(supportsInlineVideo, isTrue);
      } finally {
        await _clearImages(tester);
      }
    },
    skip: browserOnly,
    timeout: const Timeout(Duration(seconds: 45)),
  );

  testWidgets(
    'browser Ugoira conversion stays in the shared memory cache',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const url = 'https://example.test/browser-animation.zip';
      final metadata = utf8.encode(
        jsonEncode({
          'frames': [
            {'file': '000000.png', 'delay': 100},
          ],
        }),
      );
      final archive = Archive()
        ..addFile(ArchiveFile('000000.png', png.length, png))
        ..addFile(ArchiveFile('frame_data.json', metadata.length, metadata));
      final zip = Uint8List.fromList(ZipEncoder().encode(archive));
      try {
        final provider = await tester.runAsync(() async {
          await AppCacheManager.instance.putFile(
            url,
            zip,
            fileExtension: 'zip',
          );
          final converted = await cachedMediaImageProvider(url);
          expect(converted, isA<MemoryImage>());
          final bytes = (converted as MemoryImage).bytes;
          expect(ascii.decode(bytes.take(3).toList()), 'GIF');
          final cached = await getCachedUgoiraGifFile(url);
          expect(cached, isNotNull);
          expect(await cached!.readAsBytes(), orderedEquals(bytes));
          // Removing the input ZIP must still let a second viewer reuse the
          // converted GIF, without another request or conversion.
          await AppCacheManager.instance.removeFile(url);
          final reused = await cachedMediaImageProvider(url);
          expect(reused, isA<MemoryImage>());
          expect((reused as MemoryImage).bytes, orderedEquals(bytes));
          return converted;
        });
        await _renderDecodedImage(tester, provider!);
      } finally {
        await _clearImages(tester);
      }
    },
    skip: browserOnly,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
