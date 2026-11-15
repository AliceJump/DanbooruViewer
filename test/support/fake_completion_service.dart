import 'package:danbooru_viewer/completion_service.dart';

class FakeCompletionService implements CompletionService {
  FakeCompletionService({this.onBootstrap, this.onSearch, this.onLookup});

  final Future<List<SearchCompletionSuggestion>> Function()? onBootstrap;
  final Future<List<SearchCompletionSuggestion>> Function(String query)?
  onSearch;
  final Future<Map<String, CompletionTagInfo>> Function(List<String> tags)?
  onLookup;
  final List<String> queries = [];
  final List<List<String>> lookups = [];
  int bootstrapCalls = 0;
  int disposeCalls = 0;

  @override
  Future<List<SearchCompletionSuggestion>> bootstrap() async {
    bootstrapCalls++;
    return onBootstrap == null ? [] : await onBootstrap!();
  }

  @override
  Future<List<SearchCompletionSuggestion>> search(
    String query, {
    int limit = 10,
  }) async {
    queries.add(query);
    return onSearch == null ? [] : await onSearch!(query);
  }

  @override
  Future<Map<String, CompletionTagInfo>> lookup(Iterable<String> tags) async {
    final requested = tags.toList();
    lookups.add(requested);
    return onLookup == null ? {} : await onLookup!(requested);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
