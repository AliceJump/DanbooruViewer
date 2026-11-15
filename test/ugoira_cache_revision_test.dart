import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/ugoira_utils.dart';
import 'package:file/file.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

void main() {
  const firstRoute = NetworkSettings(mode: NetworkMode.http, port: 10808);
  const nextRoute = NetworkSettings(mode: NetworkMode.http, port: 10809);

  test('late ZIP publication cannot replace the new route cache', () async {
    var requests = 0;
    final network = AppNetworkService.forTesting(
      settings: firstRoute,
      clientFactory: (settings) => MockClient((_) async {
        requests++;
        return http.Response.bytes(
          [settings == firstRoute ? 1 : 2],
          200,
          headers: const {'cache-control': 'max-age=3600'},
        );
      }),
    );
    final cache = _PausedPutCache(AppCacheManager.forTesting(network), 'zip');
    addTearDown(() async {
      cache.release();
      network.dispose();
      await cache.emptyCache();
      await cache.dispose();
    });
    const url = 'https://example.test/paused-zip.zip';
    final old = getBoundedUgoiraZipFile(
      url,
      cacheManager: cache,
      networkService: network,
    );
    final cancelled = expectLater(
      old,
      throwsA(isA<NetworkCancelledException>()),
    );
    late final File replacement;
    try {
      await cache.entered.future;
      await network.updateSettings(nextRoute);
      replacement =
          await getBoundedUgoiraZipFile(
                url,
                cacheManager: cache,
                networkService: network,
              )
              as File;
    } finally {
      cache.release();
    }
    await cancelled;
    expect(await replacement.readAsBytes(), [2]);
    // The old disk write really completed under its original key.
    expect(await (await cache.getFileFromCache(url))!.file.readAsBytes(), [1]);
    final reused = await getBoundedUgoiraZipFile(
      url,
      cacheManager: cache,
      networkService: network,
    );
    expect(reused.path, replacement.path);
    expect(await reused.readAsBytes(), [2]);
    expect(requests, 2);
  });

  test(
    'late converted GIF publication stays isolated and current GIF is reused',
    () async {
      final oldZip = _oneFrameZip(red: 255, blue: 0);
      final newZip = _oneFrameZip(red: 0, blue: 255);
      var requests = 0;
      final network = AppNetworkService.forTesting(
        settings: firstRoute,
        clientFactory: (settings) => MockClient((_) async {
          requests++;
          return http.Response.bytes(
            settings == firstRoute ? oldZip : newZip,
            200,
          );
        }),
      );
      final cache = _PausedPutCache(AppCacheManager.forTesting(network), 'gif');
      addTearDown(() async {
        cache.release();
        network.dispose();
        await cache.emptyCache();
        await cache.dispose();
      });
      const url = 'https://example.test/paused-gif.zip';
      final old = getUgoiraGifFile(
        url,
        cacheManager: cache,
        networkService: network,
      );
      final cancelled = expectLater(
        old,
        throwsA(isA<NetworkCancelledException>()),
      );
      late final File current;
      late final File duplicate;
      try {
        await cache.entered.future;
        await network.updateSettings(nextRoute);
        final replacement = getUgoiraGifFile(
          url,
          cacheManager: cache,
          networkService: network,
        );
        final repeated = getUgoiraGifFile(
          url,
          cacheManager: cache,
          networkService: network,
        );
        current = await replacement as File;
        duplicate = await repeated as File;
      } finally {
        cache.release();
      }
      await cancelled;
      expect(duplicate.path, current.path);
      _expectPixel(await current.readAsBytes(), red: 0, blue: 255);
      final oldPublished = await cache.getFileFromCache(
        ugoiraGifCacheFileName(url),
      );
      _expectPixel(await oldPublished!.file.readAsBytes(), red: 255, blue: 0);
      final cached = await getCachedUgoiraGifFile(
        url,
        cacheManager: cache,
        networkService: network,
      );
      expect(cached!.path, current.path);
      final reused = await getUgoiraGifFile(
        url,
        cacheManager: cache,
        networkService: network,
      );
      expect(reused.path, current.path);
      _expectPixel(await reused.readAsBytes(), red: 0, blue: 255);
      expect(
        requests,
        2,
        reason: 'pending and converted GIFs share the active generation key',
      );
    },
  );

  test('ZIP cache preserves HTTP freshness and ETag', () async {
    final network = AppNetworkService.forTesting(
      clientFactory: (_) => MockClient(
        (_) async => http.Response.bytes(
          [1, 2],
          200,
          headers: const {'cache-control': 'max-age=120', 'etag': '"zip-v2"'},
        ),
      ),
    );
    final cache = AppCacheManager.forTesting(network);
    addTearDown(() async {
      network.dispose();
      await cache.emptyCache();
      await cache.dispose();
    });
    const url = 'https://example.test/freshness.zip';
    final before = DateTime.now();
    await getBoundedUgoiraZipFile(
      url,
      cacheManager: cache,
      networkService: network,
    );
    final cached = await cache.getFileFromCache(url);
    expect(cached, isNotNull);
    final lifetime = cached!.validTill.difference(before);
    expect(lifetime, greaterThanOrEqualTo(const Duration(seconds: 119)));
    expect(lifetime, lessThan(const Duration(seconds: 125)));
    expect((await cache.config.repo.get(url))!.eTag, '"zip-v2"');
  });

  test(
    'HTTP no-cache ZIP is fetched again rather than kept for 30 days',
    () async {
      var requests = 0;
      final network = AppNetworkService.forTesting(
        clientFactory: (_) => MockClient((_) async {
          requests++;
          return http.Response.bytes(
            [requests],
            200,
            headers: const {'cache-control': 'no-cache'},
          );
        }),
      );
      final cache = AppCacheManager.forTesting(network);
      addTearDown(() async {
        network.dispose();
        await cache.emptyCache();
        await cache.dispose();
      });
      const url = 'https://example.test/revalidate.zip';
      await getBoundedUgoiraZipFile(
        url,
        cacheManager: cache,
        networkService: network,
      );
      final next = await getBoundedUgoiraZipFile(
        url,
        cacheManager: cache,
        networkService: network,
      );
      expect(await next.readAsBytes(), [2]);
      expect(requests, 2);
    },
  );
}

Uint8List _oneFrameZip({required int red, required int blue}) {
  // Keep a palette so the production GIF encoder need not quantize a one-pixel
  // fixture (its neural quantizer normally samples larger real frames).
  final image = img.Image(width: 1, height: 1, withPalette: true);
  image.palette!.setRgb(0, red, 0, blue);
  image.setPixelIndex(0, 0, 0);
  final archive = Archive()
    ..add(ArchiveFile.bytes('0.png', img.encodePng(image)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void _expectPixel(Uint8List bytes, {required int red, required int blue}) {
  final image = img.decodeGif(bytes);
  expect(image, isNotNull);
  expect(image!.width, 1);
  expect(image.height, 1);
  final pixel = image.getPixel(0, 0);
  expect(pixel.r, red);
  expect(pixel.g, 0);
  expect(pixel.b, blue);
}

class _PausedPutCache extends CacheManager {
  _PausedPutCache(CacheManager cache, this.extension)
    : super.custom(
        cache.config,
        cacheStore: cache.store,
        webHelper: cache.webHelper,
      );

  final String extension;
  final entered = Completer<void>();
  final _resume = Completer<void>();
  bool _paused = false;

  void release() {
    if (!_resume.isCompleted) _resume.complete();
  }

  @override
  Future<File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    if (!_paused && fileExtension == extension) {
      _paused = true;
      entered.complete();
      await _resume.future;
    }
    return super.putFile(
      url,
      fileBytes,
      key: key,
      eTag: eTag,
      maxAge: maxAge,
      fileExtension: fileExtension,
    );
  }
}
