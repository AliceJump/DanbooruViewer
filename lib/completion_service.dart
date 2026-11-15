import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'completion_backend.dart';
import 'completion_backend_web.dart'
    if (dart.library.io) 'completion_backend_io.dart'
    as platform;
import 'completion_models.dart';

export 'completion_models.dart';

abstract interface class CompletionService {
  Future<List<SearchCompletionSuggestion>> bootstrap();
  Future<List<SearchCompletionSuggestion>> search(
    String query, {
    int limit = 10,
  });
  Future<Map<String, CompletionTagInfo>> lookup(Iterable<String> tags);
  Future<void> dispose();
}

class IndexedCompletionService implements CompletionService {
  final AssetBundle _assets;
  Future<Map<String, dynamic>>? _manifest;
  Future<CompletionBackend>? _opening;
  CompletionBackend? _backend;
  bool _disposed = false;

  IndexedCompletionService({AssetBundle? assetBundle})
    : _assets = assetBundle ?? rootBundle;

  Future<Map<String, dynamic>> _readManifest() async {
    final json = jsonDecode(
      await _assets.loadString('assets/danbooru_completion.bootstrap.json'),
    );
    if (json is! Map<String, dynamic> ||
        json['version'] != 1 ||
        json['count'] is! int ||
        (json['count'] as int) < 0 ||
        json['suggestions'] is! List) {
      throw const FormatException('Unsupported completion manifest');
    }
    for (final name in ['indexSha256', 'archiveSha256']) {
      if (json[name] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(json[name] as String)) {
        throw const FormatException('Invalid completion digest');
      }
    }
    return json;
  }

  Future<CompletionBackend> _open() async {
    if (_disposed) throw StateError('Completion service disposed');
    final manifest = await (_manifest ??= _readManifest());
    if (_disposed) throw StateError('Completion service disposed');
    final backend = platform.createCompletionBackend(
      loadArchive: () async {
        final bytes = await _assets.load(
          'assets/danbooru_completion.index.zip',
        );
        return bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
      },
      indexDigest: manifest['indexSha256'] as String,
      archiveDigest: manifest['archiveSha256'] as String,
      expectedCount: manifest['count'] as int,
    );
    _backend = backend;
    await backend.initialize();
    if (_disposed) throw StateError('Completion service disposed');
    return backend;
  }

  Future<CompletionBackend> _getBackend() => _opening ??= _open();

  @override
  Future<List<SearchCompletionSuggestion>> bootstrap() async {
    if (_disposed) throw StateError('Completion service disposed');
    final manifest = await (_manifest ??= _readManifest());
    if (_disposed) throw StateError('Completion service disposed');
    final suggestions = (manifest['suggestions'] as List)
        .cast<Map<String, dynamic>>()
        .map(SearchCompletionSuggestion.fromJson)
        .take(10)
        .toList(growable: false);
    // Hand the small initial list back before starting the large asset work.
    unawaited(
      Future<void>(() async {
        if (_disposed) return;
        try {
          await _getBackend();
        } catch (_) {
          /* surfaced by search/lookup */
        }
      }),
    );
    return suggestions;
  }

  @override
  Future<List<SearchCompletionSuggestion>> search(
    String query, {
    int limit = 10,
  }) async {
    if (_disposed) throw StateError('Completion service disposed');
    if (query.isEmpty && limit <= 10) {
      return (await bootstrap()).take(limit < 0 ? 0 : limit).toList();
    }
    return (await _getBackend()).search(query, limit: limit);
  }

  @override
  Future<Map<String, CompletionTagInfo>> lookup(Iterable<String> tags) async {
    if (_disposed) throw StateError('Completion service disposed');
    final keys = tags.where((tag) => tag.isNotEmpty).toSet();
    if (keys.isEmpty) return {};
    return (await _getBackend()).lookup(keys);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _backend?.dispose();
  }
}
