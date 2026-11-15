import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:danbooru_viewer/completion_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _deadline = Duration(seconds: 5);

class _CompletionAssets extends CachingAssetBundle {
  final ByteData manifest;
  final ByteData archive;
  Future<ByteData> Function()? manifestLoader;
  Future<ByteData> Function()? archiveLoader;
  int manifestLoads = 0;
  int archiveLoads = 0;

  _CompletionAssets(this.manifest, this.archive);

  @override
  Future<ByteData> load(String key) async {
    switch (key) {
      case 'assets/danbooru_completion.bootstrap.json':
        manifestLoads++;
        return manifestLoader == null ? manifest : await manifestLoader!();
      case 'assets/danbooru_completion.index.zip':
        archiveLoads++;
        return archiveLoader == null ? archive : await archiveLoader!();
      default:
        throw StateError('Unexpected asset: $key');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ByteData manifest;
  late ByteData archive;
  late _CompletionAssets assets;
  late IndexedCompletionService service;

  setUpAll(() async {
    final binary = await File(
      'test/fixtures/completion_index.bin',
    ).readAsBytes();
    final zip = Uint8List.fromList(
      ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile('completion_index.bin', binary.length, binary)),
      ),
    );
    archive = ByteData.sublistView(zip);
    manifest = ByteData.sublistView(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'count': ByteData.sublistView(binary).getUint32(8, Endian.little),
            'indexSha256': sha256.convert(binary).toString(),
            'archiveSha256': sha256.convert(zip).toString(),
            'suggestions': [],
          }),
        ),
      ),
    );
  });

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp(
      'completion-service-test-',
    );
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => directory.path,
    );
    assets = _CompletionAssets(manifest, archive);
    service = IndexedCompletionService(assetBundle: assets);
    addTearDown(() async {
      await service.dispose();
      messenger.setMockMethodCallHandler(pathProvider, null);
      await directory.delete(recursive: true);
    });
  });

  test(
    'failed opening can retry and concurrent callers share each attempt',
    () async {
      final requested = Completer<void>();
      final failedArchive = Completer<ByteData>();
      assets.archiveLoader = () {
        if (assets.archiveLoads == 1) {
          requested.complete();
          return failedArchive.future;
        }
        return Future.value(archive);
      };

      final failedSearch = expectLater(
        service.search('blue').timeout(_deadline),
        throwsStateError,
      );
      final failedLookup = expectLater(
        service.lookup(['blue_hair']).timeout(_deadline),
        throwsStateError,
      );
      await requested.future.timeout(_deadline);
      failedArchive.completeError(StateError('Temporary archive failure'));
      await Future.wait([failedSearch, failedLookup]);
      expect(assets.archiveLoads, 1);

      final search = service.search('blue').timeout(_deadline);
      final lookup = service.lookup(['blue_hair']).timeout(_deadline);
      await Future.wait([
        search.then(
          (results) => expect(results.first.insertValue, 'blue_hair'),
        ),
        lookup.then((results) => expect(results['blue_hair']?.label, '蓝发')),
      ]);
      expect(assets.archiveLoads, 2);
      expect(assets.manifestLoads, 1);

      expect((await service.search('blue')).first.insertValue, 'blue_hair');
      expect(assets.archiveLoads, 2);
    },
  );

  test(
    'failed manifest can be loaded again through a caching asset bundle',
    () async {
      assets.manifestLoader = () async {
        if (assets.manifestLoads == 1) {
          throw StateError('Temporary manifest failure');
        }
        return manifest;
      };

      await expectLater(
        service.lookup(['blue_hair']).timeout(_deadline),
        throwsStateError,
      );
      expect(assets.archiveLoads, 0);
      expect(
        (await service.search('blue').timeout(_deadline)).first.insertValue,
        'blue_hair',
      );
      expect(assets.manifestLoads, 2);
      expect(assets.archiveLoads, 1);
    },
  );

  test(
    'disposing a pending opening settles callers and prevents retry',
    () async {
      final requested = Completer<void>();
      final pendingArchive = Completer<ByteData>();
      assets.archiveLoader = () {
        requested.complete();
        return pendingArchive.future;
      };
      final pendingSearch = expectLater(
        service.search('blue').timeout(_deadline),
        throwsStateError,
      );
      await requested.future.timeout(_deadline);
      await service.dispose().timeout(_deadline);
      await pendingSearch;
      pendingArchive.complete(archive);

      await expectLater(service.search('blue'), throwsStateError);
      await expectLater(service.lookup(['blue_hair']), throwsStateError);
      await expectLater(service.bootstrap(), throwsStateError);
      expect(assets.archiveLoads, 1);
    },
  );
}
