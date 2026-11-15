import 'package:crypto/crypto.dart';

import 'completion_backend.dart';
import 'completion_index.dart';
import 'completion_models.dart';

CompletionBackend createCompletionBackend({
  required CompletionArchiveLoader loadArchive,
  required String indexDigest,
  required String archiveDigest,
  required int expectedCount,
}) => _WebCompletionBackend(loadArchive, archiveDigest, expectedCount);

// Flutter web has no Dart isolates. The index search yields periodically to
// the event loop; its initial archive inflation still occurs on this thread.
class _WebCompletionBackend implements CompletionBackend {
  final CompletionArchiveLoader _load;
  final String _digest;
  final int _count;
  Future<CompletionIndex>? _index;
  bool _disposed = false;
  int _generation = 0;
  final _cache = <(String, int), List<SearchCompletionSuggestion>>{};

  _WebCompletionBackend(this._load, this._digest, this._count);

  Future<CompletionIndex> _open() async {
    if (_disposed) throw StateError('Completion service disposed');
    final bytes = await _load();
    if (_disposed) throw StateError('Completion service disposed');
    if (sha256.convert(bytes).toString() != _digest) {
      throw const FormatException(
        'Completion archive does not match its manifest',
      );
    }
    final index = CompletionIndex.fromZip(bytes);
    if (index.count != _count) {
      throw const FormatException('Completion count mismatch');
    }
    return index;
  }

  @override
  Future<void> initialize() async {
    await (_index ??= _open());
  }

  @override
  Future<List<SearchCompletionSuggestion>> search(
    String query, {
    int limit = 10,
  }) async {
    final generation = ++_generation;
    final index = await (_index ??= _open());
    if (_disposed) throw StateError('Completion service disposed');
    final key = (query.toLowerCase(), limit);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final result = await index.search(
      query,
      limit: limit,
      isCancelled: () => _disposed || generation != _generation,
    );
    if (generation == _generation && !_disposed) {
      if (_cache.length >= 64) _cache.remove(_cache.keys.first);
      _cache[key] = result;
    }
    return result;
  }

  @override
  Future<Map<String, CompletionTagInfo>> lookup(Iterable<String> tags) async {
    final index = await (_index ??= _open());
    if (_disposed) throw StateError('Completion service disposed');
    return index.lookup(tags);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _cache.clear();
    _index = null;
  }
}
