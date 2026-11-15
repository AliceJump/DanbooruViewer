import 'dart:typed_data';

import 'completion_models.dart';

typedef CompletionArchiveLoader = Future<Uint8List> Function();

abstract interface class CompletionBackend {
  Future<void> initialize();
  Future<List<SearchCompletionSuggestion>> search(
    String query, {
    int limit = 10,
  });
  Future<Map<String, CompletionTagInfo>> lookup(Iterable<String> tags);
  Future<void> dispose();
}
