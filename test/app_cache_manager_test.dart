import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'cache uses current transport and a cancelled old download can be retried',
    () async {
      final entered = Completer<void>();
      final oldBody = StreamController<List<int>>(
        onListen: () => entered.complete(),
      );
      var requests = 0;
      final service = AppNetworkService.forTesting(
        settings: const NetworkSettings(mode: NetworkMode.http, port: 10808),
        clientFactory: (settings) =>
            MockClient.streaming((request, body) async {
              requests++;
              if (settings.port == 10808) {
                return http.StreamedResponse(
                  oldBody.stream,
                  200,
                  headers: {'content-length': '1000'},
                );
              }
              return http.StreamedResponse(
                Stream.value(utf8.encode('complete image')),
                200,
                headers: {'cache-control': 'max-age=3600'},
              );
            }),
      );
      final cache = AppCacheManager.forTesting(service);
      addTearDown(() async {
        service.dispose();
        await oldBody.close();
        await cache.dispose();
      });
      const url = 'https://example.test/image.jpg';
      final oldRequest = expectLater(
        cache.getSingleFile(url),
        throwsA(isA<NetworkCancelledException>()),
      );
      await entered.future;
      await service.updateSettings(
        const NetworkSettings(mode: NetworkMode.http, port: 10809),
      );
      final replacement = cache.getSingleFile(url);
      await oldRequest;
      expect(await (await replacement).readAsString(), 'complete image');
      expect(requests, 2);
      expect(
        await (await cache.getSingleFile(url)).readAsString(),
        'complete image',
      );
      expect(requests, 2, reason: 'a valid downloaded file is reused');
    },
  );
}
