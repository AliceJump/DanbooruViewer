import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/network/web_cache_store.dart';
import 'package:file/file.dart' as file;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('browser memory cache behavior on every platform', () {
    late AppNetworkService service;
    late CacheManager cache;

    setUp(() {
      service = AppNetworkService.forTesting();
      cache = AppCacheManager.forTesting(service);
    });
    tearDown(() async {
      await cache.emptyCache();
      await cache.dispose();
      service.dispose();
    });

    test('301 objects evict the least recently used physical file', () async {
      final first = await cache.putFile(
        'https://example.test/0',
        Uint8List.fromList([0]),
      );
      for (var i = 1; i < 300; i++) {
        await cache.putFile(
          'https://example.test/$i',
          Uint8List.fromList([i % 256]),
        );
      }
      // Reading the first file protects it; object 1 must be the eviction victim.
      expect(await cache.getFileFromCache('https://example.test/0'), isNotNull);
      final victim = await cache.config.repo.get('https://example.test/1');
      expect(victim?.id, isNotNull);
      final victimFile = await cache.config.fileSystem.createFile(
        victim!.relativePath,
      );
      await cache.putFile('https://example.test/300', Uint8List.fromList([44]));
      final latest = await cache.getFileFromCache('https://example.test/300');
      expect(await latest!.file.readAsBytes(), [44]);
      expect(await cache.getFileFromCache('https://example.test/1'), isNull);
      expect(await victimFile.exists(), isFalse);
      expect(await first.exists(), isTrue);
      expect(await first.parent.list().length, 300);
      expect(await cache.config.repo.getAllObjects(), hasLength(300));
    });

    test('removeFile and emptyCache release both files and metadata', () async {
      final first = await cache.putFile(
        'https://example.test/first',
        Uint8List.fromList([1]),
      );
      final second = await cache.putFile(
        'https://example.test/second',
        Uint8List.fromList([2, 3]),
      );
      expect(await cache.store.getCacheSize(), 3);
      await cache.removeFile('https://example.test/first');
      expect(await first.exists(), isFalse);
      expect(
        await cache.getFileFromCache('https://example.test/first'),
        isNull,
      );
      expect(await cache.config.repo.get('https://example.test/first'), isNull);
      expect(await second.exists(), isTrue);
      await cache.emptyCache();
      expect(await second.exists(), isFalse);
      expect(await second.parent.list().toList(), isEmpty);
      expect(await cache.config.repo.getAllObjects(), isEmpty);
      expect(
        await cache.getFileFromCache('https://example.test/second'),
        isNull,
      );
      await cache.removeFile('https://example.test/missing');
    });

    test(
      'replacement reuses a key and stale entries are physically removed',
      () async {
        const url = 'https://example.test/replaced';
        final original = await cache.putFile(url, Uint8List.fromList([1]));
        final replacement = await cache.putFile(
          url,
          Uint8List.fromList([2, 3]),
        );
        expect(await cache.store.getCacheSize(), 2);
        expect(original.path, replacement.path);
        expect(await replacement.parent.list().length, 1);
        final old = await cache.config.repo.get(url);
        await cache.config.repo.update(
          CacheObject(
            old!.url,
            key: old.key,
            id: old.id,
            relativePath: old.relativePath,
            validTill: old.validTill,
            touched: DateTime.now().subtract(const Duration(days: 31)),
          ),
          setTouchedToNow: false,
        );
        await cache.putFile(
          'https://example.test/fresh',
          Uint8List.fromList([4]),
        );
        expect(await cache.getFileFromCache(url), isNull);
        expect(await replacement.exists(), isFalse);
      },
    );

    testWidgets('web storage leaves no background cleanup timers', (
      tester,
    ) async {
      // Keep this cache's futures in this test's fake-async zone, rather than
      // borrowing the cache created by the plain-test setUp above.
      final widgetCache = AppCacheManager.forTesting(service);
      expect(widgetCache.store, isA<WebCacheStore>());
      await widgetCache.putFile(
        'https://example.test/widget',
        Uint8List.fromList([1]),
      );
      expect(
        await widgetCache.getFileFromCache('https://example.test/widget'),
        isNotNull,
      );
      await widgetCache.emptyCache();
      await widgetCache.dispose();
    });
  });

  for (final status in [304, 403, 503, 206]) {
    test('cache immediately cancels an unconsumed $status body', () async {
      var cancelled = 0;
      final body = StreamController<List<int>>(onCancel: () => cancelled++);
      final client = _ResponseClient(
        http.StreamedResponse(body.stream, status),
      );
      final service = AppNetworkService.forTesting(
        clientFactory: (_) => client,
        maxAttempts: 1,
      );
      final cache = AppCacheManager.forTesting(service);
      addTearDown(() async {
        service.dispose();
        await body.close();
        await cache.dispose();
      });
      const url = 'https://example.test/status';
      await cache.putFile(
        url,
        Uint8List.fromList([1]),
        maxAge: Duration.zero,
        eTag: 'old',
      );
      if (status == 304) {
        final cached = await cache.downloadFile(url);
        expect(await cached.file.readAsBytes(), [1]);
      } else {
        await expectLater(
          cache.downloadFile(url),
          throwsA(isA<HttpExceptionWithStatus>()),
        );
      }
      expect(cancelled, 1, reason: 'no timeout or body drain is required');
      expect(client.closed, isTrue);
    });
  }

  test(
    'emptyCache also releases partial bytes from a failed download',
    () async {
      Stream<List<int>> failingBody() async* {
        yield [1, 2, 3];
        throw StateError('connection interrupted');
      }

      final service = AppNetworkService.forTesting(
        clientFactory: (_) => MockClient.streaming(
          (_, _) async => http.StreamedResponse(failingBody(), 200),
        ),
      );
      final cache = AppCacheManager.forTesting(service);
      addTearDown(() async {
        service.dispose();
        await cache.dispose();
      });
      const url = 'https://example.test/interrupted';
      await expectLater(
        cache.getSingleFile(url),
        throwsA(isA<NetworkException>()),
      );
      expect(await cache.getFileFromCache(url), isNull);
      final root = (await cache.config.fileSystem.createFile(
        'sentinel',
      )).parent;
      expect(
        await root.list().length,
        1,
        reason: 'upstream left an unpublished partial file',
      );
      await cache.emptyCache();
      expect(await root.list().toList(), isEmpty);
      expect(await cache.config.repo.getAllObjects(), isEmpty);
    },
  );

  test(
    'a paused old disk write cannot block the replacement cache generation',
    () async {
      final fileSystem = _PausingCacheFileSystem();
      final oldBody = StreamController<List<int>>();
      var requests = 0;
      final service = AppNetworkService.forTesting(
        settings: const NetworkSettings(mode: NetworkMode.http, port: 10808),
        clientFactory: (settings) => MockClient.streaming((_, _) async {
          requests++;
          return http.StreamedResponse(
            settings.port == 10808
                ? oldBody.stream
                : Stream.value(utf8.encode('new route')),
            200,
          );
        }),
      );
      final cache = AppCacheManager.forTesting(service, fileSystem: fileSystem);
      addTearDown(() async {
        if (!fileSystem.resume.isCompleted) fileSystem.resume.complete();
        service.dispose();
        await oldBody.close();
        await cache.dispose();
      });
      const url = 'https://example.test/paused.jpg';
      var oldFinished = false;
      final oldRequest = expectLater(
        cache.getSingleFile(url),
        throwsA(isA<NetworkCancelledException>()),
      ).then((_) => oldFinished = true);
      oldBody.add([1]);
      await fileSystem.paused.future;
      await service.updateSettings(
        const NetworkSettings(mode: NetworkMode.http, port: 10809),
      );
      final replacement = await cache
          .getSingleFile(url)
          .timeout(const Duration(seconds: 2));
      expect(await replacement.readAsString(), 'new route');
      expect(
        oldFinished,
        isFalse,
        reason: 'the old subject is demonstrably still blocked',
      );
      expect(requests, 2);
      fileSystem.resume.complete();
      await oldRequest;
      expect(
        await (await cache.getSingleFile(url)).readAsString(),
        'new route',
      );
      expect(requests, 2);
    },
  );

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

class _ResponseClient extends http.BaseClient {
  _ResponseClient(this.response);
  final http.StreamedResponse response;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
  @override
  void close() => closed = true;
}

class _PausingCacheFileSystem implements FileSystem {
  final _delegate = MemoryCacheSystem();
  final paused = Completer<void>();
  final resume = Completer<void>();
  bool claimed = false;

  @override
  Future<file.File> createFile(String name) async =>
      _PausingFile(await _delegate.createFile(name), this);
}

/// Only openWrite differs from the real memory file. Unexpected IO fails loudly.
class _PausingFile implements file.File {
  _PausingFile(this.delegate, this.owner);
  final file.File delegate;
  final _PausingCacheFileSystem owner;
  @override
  String get path => delegate.path;
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<file.FileSystemEntity> delete({bool recursive = false}) =>
      delegate.delete(recursive: recursive);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      delegate.readAsString(encoding: encoding);
  @override
  io.IOSink openWrite({
    io.FileMode mode = io.FileMode.write,
    Encoding encoding = utf8,
  }) => _PausingSink(delegate.openWrite(mode: mode, encoding: encoding), owner);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PausingSink implements io.IOSink {
  _PausingSink(this.delegate, this.owner);
  final io.IOSink delegate;
  final _PausingCacheFileSystem owner;

  @override
  Future<void> addStream(Stream<List<int>> stream) => delegate.addStream(
    stream.asyncMap((chunk) async {
      if (!owner.claimed) {
        owner.claimed = true;
        owner.paused.complete();
        await owner.resume.future;
      }
      return chunk;
    }),
  );
  @override
  Future<void> close() async {
    await delegate.close();
  }

  @override
  Future<void> get done async {
    await delegate.done;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
