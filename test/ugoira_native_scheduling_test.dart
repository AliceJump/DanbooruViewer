@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/ugoira_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

Uint8List _oneFrameZip() {
  final frame = img.Image(width: 1, height: 1, withPalette: true);
  frame.palette!.setRgb(0, 255, 0, 0);
  frame.setPixelIndex(0, 0, 0);
  return Uint8List.fromList(
    ZipEncoder().encode(
      Archive()..add(ArchiveFile.bytes('0.png', img.encodePng(frame))),
    ),
  );
}

void main() {
  test(
    'native grid waits before downloading and completes more than four GIFs',
    () async {
      final zip = _oneFrameZip();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final requested = <String>[];
      final network = AppNetworkService.forTesting(
        clientFactory: (_) => MockClient((request) async {
          requested.add(request.url.path);
          if (requested.length == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          return http.Response.bytes(zip, 200);
        }),
      );
      final cache = AppCacheManager.forTesting(network);
      addTearDown(() async {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
        network.dispose();
        await cache.emptyCache();
        await cache.dispose();
      });
      final pending = List.generate(
        8,
        (index) => getUgoiraGifFile(
          'https://example.test/grid-$index.zip',
          cacheManager: cache,
          networkService: network,
        ),
      );
      await firstStarted.future;
      // Let every cache lookup reach its deferred conversion admission point.
      await Future<void>.delayed(Duration.zero);
      final requestsWhileFirstBlocked = requested.length;
      releaseFirst.complete();
      final files = await Future.wait(pending);
      expect(requestsWhileFirstBlocked, 1);
      expect(requested.length, 8);
      for (final file in files) {
        final gif = img.decodeGif(await file.readAsBytes());
        expect(gif, isNotNull);
        expect(gif!.width, 1);
        expect(gif.getPixel(0, 0).r, 255);
      }
    },
  );

  test(
    'cached GIF bypasses the slot and a cancelled queued ZIP is never fetched',
    () async {
      final zip = _oneFrameZip();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final requested = <String>[];
      final network = AppNetworkService.forTesting(
        clientFactory: (_) => MockClient((request) async {
          requested.add(request.url.path);
          firstStarted.complete();
          await releaseFirst.future;
          return http.Response.bytes(zip, 200);
        }),
      );
      final cache = AppCacheManager.forTesting(network);
      addTearDown(() async {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
        network.dispose();
        await cache.emptyCache();
        await cache.dispose();
      });
      const cachedUrl = 'https://example.test/cached.zip';
      final cached = await cache.putFile(
        cachedUrl,
        mergeUgoiraBytesToGifSync(zip),
        key: ugoiraGifCacheFileName(cachedUrl),
        fileExtension: 'gif',
      );
      final active = getUgoiraGifFile(
        'https://example.test/active.zip',
        cacheManager: cache,
        networkService: network,
      );
      await firstStarted.future;
      final token = NetworkCancelToken();
      final cancelled = expectLater(
        getUgoiraGifFile(
          'https://example.test/cancelled.zip',
          cacheManager: cache,
          networkService: network,
          cancelToken: token,
        ),
        throwsA(isA<NetworkCancelledException>()),
      );
      // Let the non-cached request enqueue behind the blocked download.
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await cancelled;
      final reused = await getUgoiraGifFile(
        cachedUrl,
        cacheManager: cache,
        networkService: network,
      );
      expect(reused.path, cached.path);
      expect(requested, ['/active.zip']);
      releaseFirst.complete();
      await active;
      expect(requested, ['/active.zip']);
    },
  );
}
