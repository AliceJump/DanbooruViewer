import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:danbooru_viewer/completion_backend_io.dart';
import 'package:danbooru_viewer/completion_index.dart';
import 'package:flutter_test/flutter_test.dart';

const _deadline = Duration(seconds: 5);

Future<void> _waitForCache(File cache, String digest) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < _deadline) {
    try {
      if (await cache.exists() &&
          sha256.convert(await cache.readAsBytes()).toString() == digest) {
        return;
      }
    } on FileSystemException {
      // The worker announces readiness before its atomic cache write finishes.
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('The worker did not finish writing a valid cache within $_deadline');
}

void main() {
  late Uint8List binary;
  late Uint8List archive;
  late String indexDigest;
  late String archiveDigest;
  late int count;
  late Directory directory;

  setUpAll(() async {
    binary = await File('test/fixtures/completion_index.bin').readAsBytes();
    archive = Uint8List.fromList(
      ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile('completion_index.bin', binary.length, binary)),
      ),
    );
    indexDigest = sha256.convert(binary).toString();
    archiveDigest = sha256.convert(archive).toString();
    count = ByteData.sublistView(binary).getUint32(8, Endian.little);
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'completion-worker-test-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  NativeCompletionBackend createBackend({
    Future<Uint8List> Function()? load,
    String? expectedIndexDigest,
    String? expectedArchiveDigest,
    String? cachePath,
  }) {
    final backend = NativeCompletionBackend(
      loadArchive: load ?? () async => archive,
      indexDigest: expectedIndexDigest ?? indexDigest,
      archiveDigest: expectedArchiveDigest ?? archiveDigest,
      expectedCount: count,
      cacheDirectory: () async => cachePath ?? directory.path,
    );
    addTearDown(backend.dispose);
    return backend;
  }

  for (final suffix in ['', Platform.pathSeparator]) {
    test(
      'cold and warm workers reuse cache with ${suffix.isEmpty ? 'normal path' : 'trailing separator'}',
      () async {
        var loads = 0;
        final cold = createBackend(
          cachePath: '${directory.path}$suffix',
          load: () async {
            loads++;
            return archive;
          },
        );
        await Future.wait([
          cold.initialize(),
          cold.initialize(),
        ]).timeout(_deadline);
        final suggestions = await cold.search('blue').timeout(_deadline);
        expect(suggestions.first.insertValue, 'blue_hair');
        final metadata = await cold.lookup(['blue_hair']).timeout(_deadline);
        expect(metadata['blue_hair']?.label, '蓝发');
        expect(metadata['blue_hair']?.category, 0);
        expect(loads, 1);

        final cache = File('${directory.path}/$indexDigest.bin');
        await _waitForCache(cache, indexDigest);
        await cold.dispose();

        final warm = createBackend(
          load: () async {
            loads++;
            throw StateError(
              'A valid cache must not request the compressed asset',
            );
          },
        );
        await warm.initialize().timeout(_deadline);
        final warmSuggestions = await warm.search('blue').timeout(_deadline);
        expect(
          warmSuggestions.map((suggestion) => suggestion.value),
          suggestions.map((suggestion) => suggestion.value),
        );
        expect(loads, 1);
      },
    );
  }

  test(
    'same-length cache corruption is rejected and repaired from the archive',
    () async {
      final corrupt = Uint8List.fromList(binary);
      final searchStart = 24 + count * 36;
      corrupt[searchStart] ^= 0x20;
      // A changed string byte leaves the header, sizes, and record count valid.
      expect(CompletionIndex(corrupt).count, count);
      final cache = File('${directory.path}/$indexDigest.bin');
      await cache.writeAsBytes(corrupt, flush: true);

      var loads = 0;
      final backend = createBackend(
        load: () async {
          loads++;
          return archive;
        },
      );
      await backend.initialize().timeout(_deadline);
      expect(loads, 1);
      expect(
        (await backend.search('blue').timeout(_deadline)).first.value,
        'blue_hair',
      );
      await _waitForCache(cache, indexDigest);
      expect(await cache.readAsBytes(), binary);
    },
  );

  test(
    'a bad archive fails initialization and later requests without hanging',
    () async {
      final invalidArchive = Uint8List.fromList([1, 2, 3]);
      final backend = createBackend(
        load: () async => invalidArchive,
        expectedArchiveDigest: sha256.convert(invalidArchive).toString(),
      );
      await expectLater(
        backend.initialize().timeout(_deadline),
        throwsStateError,
      );
      await expectLater(
        backend.search('blue').timeout(_deadline),
        throwsStateError,
      );
      await expectLater(
        backend.lookup(['blue_hair']).timeout(_deadline),
        throwsStateError,
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'a fresh archive must also match the uncompressed index digest',
    () async {
      final backend = createBackend(expectedIndexDigest: '0' * 64);
      await expectLater(
        backend.initialize().timeout(_deadline),
        throwsStateError,
      );
      await expectLater(
        backend.search('blue').timeout(_deadline),
        throwsStateError,
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'disposing during a pending asset load settles readiness and requests',
    () async {
      final asset = Completer<Uint8List>();
      final requested = Completer<void>();
      final backend = createBackend(
        load: () {
          requested.complete();
          return asset.future;
        },
      );
      final readiness = expectLater(
        backend.initialize().timeout(_deadline),
        throwsStateError,
      );
      await requested.future.timeout(_deadline);
      await backend.dispose().timeout(_deadline);
      await readiness;
      asset.complete(archive);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        backend.search('blue').timeout(_deadline),
        throwsStateError,
      );
      await expectLater(
        backend.lookup(['blue_hair']).timeout(_deadline),
        throwsStateError,
      );
    },
  );

  test(
    'disposing a ready worker rejects queued and subsequent requests',
    () async {
      final backend = createBackend();
      await backend.initialize().timeout(_deadline);
      final queued = expectLater(
        backend.search('blue').timeout(_deadline),
        throwsStateError,
      );
      await backend.dispose().timeout(_deadline);
      await queued;
      await expectLater(
        backend.search('blue').timeout(_deadline),
        throwsStateError,
      );
      await expectLater(
        backend.lookup(['blue_hair']).timeout(_deadline),
        throwsStateError,
      );
      await backend.dispose().timeout(_deadline);
    },
  );
}
