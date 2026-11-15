import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// The default store deletes dart:io files and schedules an uncancellable timer.
// Override its storage operations so the web cache uses its actual memory FS.
// ignore: implementation_imports
import 'package:flutter_cache_manager/src/cache_store.dart';

/// Metadata for the session-only browser cache, in least-recently-used order.
class WebCacheRepository implements CacheInfoRepository {
  final _objects = <String, CacheObject>{};
  int _nextId = 0;

  bool containsKey(String key) => _objects.containsKey(key);

  CacheObject _save(CacheObject object, {required bool touch}) {
    final existing = _objects[object.key];
    final stored = CacheObject(
      object.url,
      key: object.key,
      id: existing?.id ?? ++_nextId,
      relativePath: object.relativePath,
      validTill: object.validTill,
      eTag: object.eTag,
      length: object.length,
      touched: touch ? DateTime.now() : object.touched,
    );
    if (touch) _objects.remove(object.key);
    _objects[object.key] = stored;
    return stored;
  }

  @override
  Future<CacheObject> insert(
    CacheObject object, {
    bool setTouchedToNow = true,
  }) async => _save(object, touch: setTouchedToNow);

  @override
  Future<CacheObject> updateOrInsert(CacheObject object) => insert(object);

  @override
  Future<int> update(CacheObject object, {bool setTouchedToNow = true}) async {
    if (!_objects.containsKey(object.key)) return 0;
    _save(object, touch: setTouchedToNow);
    return 1;
  }

  @override
  Future<CacheObject?> get(String key) async => _objects[key];

  @override
  Future<List<CacheObject>> getAllObjects() async => _objects.values.toList();

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async =>
      _objects.values
          .take((_objects.length - capacity).clamp(0, _objects.length))
          .toList();

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async {
    final cutoff = DateTime.now().subtract(maxAge);
    return _objects.values
        .where((object) => object.touched?.isBefore(cutoff) ?? true)
        .toList();
  }

  @override
  Future<int> delete(int id) => deleteAll([id]);

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    final selected = ids.toSet();
    final before = _objects.length;
    _objects.removeWhere((_, object) => selected.contains(object.id));
    return before - _objects.length;
  }

  @override
  Future<bool> exists() async => _objects.isNotEmpty;

  @override
  Future<bool> open() async => true;

  @override
  Future<bool> close() async => true;

  @override
  Future<void> deleteDataFile() async => _objects.clear();
}

/// Bounded object-count cache for Web. Files and metadata share one lifetime;
/// cleanup runs with mutations, without native IO or background timers.
class WebCacheStore extends CacheStore {
  WebCacheStore(super.config, this.repository)
    : _capacity = config.maxNrOfCacheObjects,
      _maxAge = config.stalePeriod;

  final WebCacheRepository repository;
  final int _capacity;
  final Duration _maxAge;
  Future<void> _pending = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _remove(CacheObject object) async {
    final file = await fileSystem.createFile(object.relativePath);
    if (await file.exists()) await file.delete();
    if (object.id != null) await repository.delete(object.id!);
  }

  Future<CacheObject?> _retrieve(String key) async {
    final object = await repository.get(key);
    if (object == null) return null;
    final file = await fileSystem.createFile(object.relativePath);
    if (!await file.exists()) {
      await repository.delete(object.id!);
      return null;
    }
    return repository.updateOrInsert(object);
  }

  @override
  Future<CacheObject?> retrieveCacheData(
    String key, {
    bool ignoreMemCache = false,
  }) => _serialize(() => _retrieve(key));

  @override
  Future<FileInfo?> getFile(String key, {bool ignoreMemCache = false}) =>
      _serialize(() async {
        final object = await _retrieve(key);
        if (object == null) return null;
        final file = await fileSystem.createFile(object.relativePath);
        return FileInfo(file, FileSource.Cache, object.validTill, object.url);
      });

  @override
  Future<void> putFile(CacheObject cacheObject) => _serialize(() async {
    final previous = await repository.get(cacheObject.key);
    await repository.updateOrInsert(cacheObject);
    if (previous != null && previous.relativePath != cacheObject.relativePath) {
      final file = await fileSystem.createFile(previous.relativePath);
      if (await file.exists()) await file.delete();
    }
    for (final old in await repository.getOldObjects(_maxAge)) {
      await _remove(old);
    }
    for (final old in await repository.getObjectsOverCapacity(_capacity)) {
      await _remove(old);
    }
  });

  @override
  Future<FileInfo?> getFileFromMemory(String key) => getFile(key);

  @override
  Future<void> removeCachedFile(CacheObject cacheObject) =>
      _serialize(() async {
        final current = await repository.get(cacheObject.key);
        if (current != null) await _remove(current);
      });

  @override
  Future<void> emptyCache() => _serialize(() async {
    // A failed upstream download can leave a partial file with no metadata.
    // This directory belongs exclusively to this memory cache; clear those
    // orphaned bytes as well as successfully published objects.
    final root = (await fileSystem.createFile('cache-root')).parent;
    await for (final entry in root.list()) {
      await entry.delete(recursive: true);
    }
    await repository.deleteDataFile();
  });

  // The repository is itself the memory cache; there is no second lookup cache.
  @override
  void emptyMemoryCache() {}

  @override
  bool memoryCacheContainsKey(String key) => repository.containsKey(key);

  @override
  Future<int> getCacheSize() => _serialize(() async {
    var bytes = 0;
    for (final object in await repository.getAllObjects()) {
      final file = await fileSystem.createFile(object.relativePath);
      if (await file.exists()) bytes += await file.length();
    }
    return bytes;
  });

  @override
  Future<void> dispose() async {
    await _pending;
    await repository.close();
  }
}
