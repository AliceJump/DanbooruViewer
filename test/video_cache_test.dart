import 'dart:async';

import 'package:danbooru_viewer/media_utils.dart';
import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'https://example.test/video.webm?signature=test';

  test(
    'video cache publishes complete bytes and reuses them without a second request',
    () async {
      var requests = 0;
      final network = AppNetworkService.forTesting(
        clientFactory: (_) => MockClient((_) async {
          requests++;
          return http.Response.bytes([1, 2, 3, 4], 200);
        }),
      );
      final cache = AppCacheManager.forTesting(network);
      cache.store.cleanupRunMinInterval = Duration.zero;
      final token = NetworkCancelToken();
      final file = await cacheVideoFile(
        url,
        cancelToken: token,
        cacheManager: cache,
        networkService: network,
      );
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      expect(file.path, endsWith('.webm'));
      expect((await cache.getFileFromCache(url))?.file.path, file.path);
      final cached = await cacheVideoFile(
        url,
        cancelToken: token,
        cacheManager: cache,
        networkService: network,
      );
      expect(cached.path, file.path);
      expect(requests, 1);
      expect(
        await file.parent
            .list()
            .where((entry) => entry.path.endsWith('.part'))
            .toList(),
        isEmpty,
      );
      await cache.dispose();
      network.dispose();
    },
  );

  test(
    'cancelled video stream removes partial bytes and never enters the cache',
    () async {
      final started = Completer<void>();
      final body = StreamController<List<int>>(onListen: started.complete);
      final network = AppNetworkService.forTesting(
        clientFactory: (_) => MockClient.streaming((_, _) async {
          return http.StreamedResponse(body.stream, 200, contentLength: 1000);
        }),
      );
      final cache = AppCacheManager.forTesting(network);
      cache.store.cleanupRunMinInterval = Duration.zero;
      final token = NetworkCancelToken();
      final operation = cacheVideoFile(
        url,
        cancelToken: token,
        cacheManager: cache,
        networkService: network,
      );
      final failure = expectLater(
        operation,
        throwsA(isA<NetworkCancelledException>()),
      );
      await started.future;
      body.add([1, 2]);
      token.cancel();
      await failure;
      expect(await cache.getFileFromCache(url), isNull);
      final sentinel = await cache.config.fileSystem.createFile('sentinel');
      expect(await sentinel.parent.list().toList(), isEmpty);
      await body.close();
      await cache.dispose();
      network.dispose();
    },
  );

  test('a truncated video is rejected before cache publication', () async {
    final network = AppNetworkService.forTesting(
      clientFactory: (_) => MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value([1, 2]),
          200,
          contentLength: 1000,
        ),
      ),
    );
    final cache = AppCacheManager.forTesting(network);
    cache.store.cleanupRunMinInterval = Duration.zero;
    await expectLater(
      cacheVideoFile(
        url,
        cancelToken: NetworkCancelToken(),
        cacheManager: cache,
        networkService: network,
      ),
      throwsA(isA<NetworkException>()),
    );
    expect(await cache.getFileFromCache(url), isNull);
    final sentinel = await cache.config.fileSystem.createFile('sentinel');
    expect(await sentinel.parent.list().toList(), isEmpty);
    await cache.dispose();
    network.dispose();
  });
}
