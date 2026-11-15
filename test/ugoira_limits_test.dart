import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/ugoira_archive.dart';
import 'package:danbooru_viewer/ugoira_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Uint8List _zip(Map<String, List<int>> files, {int level = 6, String? comment}) {
  final archive = Archive()..comment = comment;
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive, level: level));
}

List<int> _centralHeaders(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final eocd = bytes.length - 22;
  var offset = data.getUint32(eocd + 16, Endian.little);
  final result = <int>[];
  while (offset < eocd) {
    result.add(offset);
    offset +=
        46 +
        data.getUint16(offset + 28, Endian.little) +
        data.getUint16(offset + 30, Endian.little) +
        data.getUint16(offset + 32, Endian.little);
  }
  return result;
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.response);
  final http.StreamedResponse response;
  int sends = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    return response;
  }

  @override
  void close() => closed = true;
}

void main() {
  group('actual ZIP output limits', () {
    for (final level in [0, 6]) {
      test('ordinary ZIP method at level $level decodes and verifies CRC', () {
        final bytes = _zip({
          'a.txt': [1, 2, 3, 4],
        }, level: level);
        final result = decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 4);
        expect(result.files.single.content, [1, 2, 3, 4]);
      });
    }

    test('forged small length cannot bypass the actual deflate budget', () {
      final bytes = _zip({'frame.png': List<int>.filled(4096, 65)});
      final data = ByteData.sublistView(bytes);
      final header = _centralHeaders(bytes).single;
      expect(data.getUint16(header + 10, Endian.little), 8);
      data.setUint32(header + 24, 1, Endian.little);
      expect(
        () => decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 128),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'reason',
            contains('超出限制'),
          ),
        ),
      );
    });

    test('actual output budget is shared by all files', () {
      final bytes = _zip({
        'one.png': List<int>.filled(60, 1),
        'two.png': List<int>.filled(60, 2),
      });
      final header = _centralHeaders(bytes).last;
      ByteData.sublistView(bytes).setUint32(header + 24, 1, Endian.little);
      expect(
        () => decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 70),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'reason',
            contains('实际解压大小超出限制'),
          ),
        ),
      );
    });

    test('metadata has a smaller limit before JSON object expansion', () {
      final bytes = _zip({
        'frame_data.json': List<int>.filled(maxUgoiraMetadataBytes + 1, 32),
      });
      expect(
        () =>
            decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 2 * 1024 * 1024),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'reason',
            contains('元数据'),
          ),
        ),
      );
    });

    test('corrupt CRC, understated count and symbolic links are rejected', () {
      for (final kind in ['crc', 'count', 'symlink']) {
        final bytes = _zip({
          'a.txt': [1, 2, 3],
          'b.txt': [4],
        });
        final data = ByteData.sublistView(bytes);
        final header = _centralHeaders(bytes).first;
        switch (kind) {
          case 'crc':
            data.setUint32(header + 16, 0, Endian.little);
          case 'count':
            data.setUint16(bytes.length - 22 + 8, 1, Endian.little);
            data.setUint16(bytes.length - 22 + 10, 1, Endian.little);
          case 'symlink':
            data.setUint32(header + 38, 0xa000 << 16, Endian.little);
        }
        expect(
          () => decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 100),
          throwsA(isA<FormatException>()),
          reason: kind,
        );
      }
    });

    test('an EOCD-like signature inside a comment cannot redirect parsing', () {
      final bytes = _zip({
        'a.txt': [7],
      }, comment: 'PK\u0005\u0006not-a-directory');
      expect(
        decodeBoundedUgoiraArchive(
          bytes,
          maxOutputBytes: 1,
        ).files.single.content,
        [7],
      );
    });

    test('file count limit is enforced before decoding entries', () {
      final bytes = _zip({
        'one': [1],
        'two': [2],
      });
      expect(
        () =>
            decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 100, maxFiles: 1),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('bounded download publication', () {
    test(
      'unknown-length overflow cancels immediately and is never cached',
      () async {
        final listened = Completer<void>();
        var cancelled = 0;
        final body = StreamController<List<int>>(
          onListen: listened.complete,
          onCancel: () => cancelled++,
        );
        final client = _StreamClient(http.StreamedResponse(body.stream, 200));
        final service = AppNetworkService.forTesting(
          clientFactory: (_) => client,
        );
        final cache = AppCacheManager.forTesting(service);
        addTearDown(() async {
          service.dispose();
          await body.close();
          await cache.emptyCache();
          await cache.dispose();
        });
        const url = 'https://example.test/too-large.zip';
        final future = getBoundedUgoiraZipFile(
          url,
          cacheManager: cache,
          networkService: service,
          maxBytes: 4,
        );
        final rejected = expectLater(future, throwsA(isA<FormatException>()));
        await listened.future;
        body.add([1, 2, 3]);
        body.add([4, 5]);
        await rejected;
        expect(cancelled, 1);
        expect(client.closed, isTrue);
        expect(await cache.getFileFromCache(url), isNull);
        expect(await cache.config.repo.getAllObjects(), isEmpty);
      },
    );

    test(
      'exact-limit download publishes once and reuses the cached file',
      () async {
        final client = _StreamClient(
          http.StreamedResponse(Stream.value([1, 2, 3, 4]), 200),
        );
        final service = AppNetworkService.forTesting(
          clientFactory: (_) => client,
        );
        final cache = AppCacheManager.forTesting(service);
        addTearDown(() async {
          service.dispose();
          await cache.emptyCache();
          await cache.dispose();
        });
        const url = 'https://example.test/complete.zip';
        for (var i = 0; i < 2; i++) {
          final file = await getBoundedUgoiraZipFile(
            url,
            cacheManager: cache,
            networkService: service,
            maxBytes: 4,
          );
          expect(await file.readAsBytes(), [1, 2, 3, 4]);
        }
        expect(client.sends, 1);
      },
    );

    test(
      'expired ZIP bytes are fetched again through the bounded path',
      () async {
        final client = _StreamClient(
          http.StreamedResponse(Stream.value([2, 3]), 200),
        );
        final service = AppNetworkService.forTesting(
          clientFactory: (_) => client,
        );
        final cache = AppCacheManager.forTesting(service);
        addTearDown(() async {
          service.dispose();
          await cache.emptyCache();
          await cache.dispose();
        });
        const url = 'https://example.test/expired.zip';
        await cache.putFile(
          url,
          Uint8List.fromList([1]),
          maxAge: const Duration(days: -1),
        );
        final result = await getBoundedUgoiraZipFile(
          url,
          cacheManager: cache,
          networkService: service,
          maxBytes: 4,
        );
        expect(await result.readAsBytes(), [2, 3]);
        expect(client.sends, 1);
      },
    );

    test('oversized legacy cache is physically removed before use', () async {
      final service = AppNetworkService.forTesting();
      final cache = AppCacheManager.forTesting(service);
      addTearDown(() async {
        service.dispose();
        await cache.emptyCache();
        await cache.dispose();
      });
      const url = 'https://example.test/legacy.zip';
      final file = await cache.putFile(
        url,
        Uint8List.fromList([1, 2, 3, 4, 5]),
      );
      await expectLater(
        getBoundedUgoiraZipFile(
          url,
          cacheManager: cache,
          networkService: service,
          maxBytes: 4,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await file.exists(), isFalse);
      expect(await cache.getFileFromCache(url), isNull);
    });
  });
}
