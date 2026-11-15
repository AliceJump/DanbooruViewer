import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'completion_backend.dart';
import 'completion_index.dart';
import 'completion_models.dart';

CompletionBackend createCompletionBackend({
  required CompletionArchiveLoader loadArchive,
  required String indexDigest,
  required String archiveDigest,
  required int expectedCount,
}) => NativeCompletionBackend(
  loadArchive: loadArchive,
  indexDigest: indexDigest,
  archiveDigest: archiveDigest,
  expectedCount: expectedCount,
);

/// One worker owns the index. The UI exchanges only queries and small results.
/// The expanded asset is cached by its build-time hash, so subsequent launches
/// read the index directly instead of inflating the archive again.
class NativeCompletionBackend implements CompletionBackend {
  final CompletionArchiveLoader loadArchive;
  final String indexDigest;
  final String archiveDigest;
  final int expectedCount;
  final Future<String?> Function()? cacheDirectory;
  final ReceivePort _events = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<Object?>> _pending = {};
  Isolate? _worker;
  SendPort? _commands;
  Future<void>? _initializing;
  bool _disposed = false;
  Object? _failure;
  int _nextRequest = 0;

  NativeCompletionBackend({
    required this.loadArchive,
    required this.indexDigest,
    required this.archiveDigest,
    required this.expectedCount,
    this.cacheDirectory,
  });

  @override
  Future<void> initialize() => _initializing ??= _start();

  Future<void> _start() async {
    if (_disposed) throw StateError('Completion service disposed');
    _events.listen(_handleEvent);
    // Attach the readiness listener before spawning: an early worker failure
    // must never become an unhandled asynchronous error.
    final readiness = _ready.future;
    unawaited(
      readiness.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      ),
    );
    String? directory;
    try {
      directory = cacheDirectory == null
          ? '${(await getTemporaryDirectory()).path}/tag_completion'
          : await cacheDirectory!();
    } catch (_) {
      // Cache availability must not disable search (for example, a platform
      // without a registered path-provider plugin).
      directory = null;
    }
    if (_disposed) throw StateError('Completion service disposed');
    try {
      final worker = await Isolate.spawn<List<Object?>>(
        _completionWorker,
        [
          _events.sendPort,
          directory,
          indexDigest,
          archiveDigest,
          expectedCount,
        ],
        onError: _events.sendPort,
        onExit: _events.sendPort,
        debugName: 'tag-completion',
      );
      if (_disposed) {
        worker.kill(priority: Isolate.immediate);
        throw StateError('Completion service disposed');
      }
      _worker = worker;
      await readiness;
    } catch (error, stack) {
      _fail(error, stack);
      rethrow;
    }
  }

  void _handleEvent(dynamic message) {
    if (_disposed) return;
    if (message == null) {
      _fail(StateError('Completion worker exited'));
      return;
    }
    if (message is! List || message.isEmpty) {
      _fail(StateError('Invalid completion worker message'));
      return;
    }
    switch (message[0]) {
      case 'port':
        _commands = message[1] as SendPort;
      case 'asset':
        unawaited(_supplyArchive());
      case 'ready':
        if (!_ready.isCompleted) _ready.complete();
      case 'error':
        _fail(StateError(message[1] as String));
      case 'result':
        final completer = _pending.remove(message[1] as int);
        if (completer == null) return;
        if (message[2] == true) {
          completer.complete(message[3]);
        } else {
          completer.completeError(StateError(message[3] as String));
        }
      default:
        _fail(StateError('Completion worker failed: ${message.first}'));
    }
  }

  Future<void> _supplyArchive() async {
    try {
      final bytes = await loadArchive();
      if (_disposed) return;
      _commands!.send([
        'load',
        TransferableTypedData.fromList([bytes]),
      ]);
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    _failure ??= error;
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    for (final completer in _pending.values) {
      completer.completeError(error, stack);
    }
    _pending.clear();
    _worker?.kill(priority: Isolate.immediate);
    _events.close();
  }

  Future<Object?> _request(String operation, Object payload) async {
    await initialize();
    if (_disposed) throw StateError('Completion service disposed');
    if (_failure != null) throw _failure!;
    final id = ++_nextRequest;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands!.send([operation, id, payload]);
    return result.future;
  }

  @override
  Future<List<SearchCompletionSuggestion>> search(
    String query, {
    int limit = 10,
  }) async {
    final result = await _request('search', (query, limit));
    return (result as List).cast<SearchCompletionSuggestion>();
  }

  @override
  Future<Map<String, CompletionTagInfo>> lookup(Iterable<String> tags) async {
    final result = await _request('lookup', tags.toList(growable: false));
    return (result as Map).cast<String, CompletionTagInfo>();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Only complete readiness when it has a listener from initialize().
    if (_initializing != null) _fail(StateError('Completion service disposed'));
    _worker?.kill(priority: Isolate.immediate);
    _events.close();
  }
}

Future<void> _completionWorker(List<Object?> args) async {
  final replies = args[0] as SendPort;
  final directory = args[1] as String?;
  final digest = args[2] as String;
  final archiveDigest = args[3] as String;
  final count = args[4] as int;
  final commands = ReceivePort();
  replies.send(['port', commands.sendPort]);
  CompletionIndex? index;
  final cache = directory == null ? null : File('$directory/$digest.bin');
  if (cache != null) {
    try {
      final cachedBytes = await cache.readAsBytes();
      if (sha256.convert(cachedBytes).toString() != digest) {
        throw const FormatException('Completion cache checksum mismatch');
      }
      final cached = CompletionIndex(cachedBytes);
      if (cached.count == count) index = cached;
    } catch (_) {
      // Missing, interrupted or structurally corrupt caches are rebuilt from
      // the shipped archive; the source asset is never modified.
    }
  }
  if (index == null) {
    replies.send(['asset']);
  } else {
    replies.send(['ready']);
  }
  var searchGeneration = 0;
  final searchCache = <(String, int), List<SearchCompletionSuggestion>>{};
  commands.listen((dynamic message) async {
    final parts = message as List;
    if (parts[0] == 'load') {
      try {
        final bytes = (parts[1] as TransferableTypedData)
            .materialize()
            .asUint8List();
        if (sha256.convert(bytes).toString() != archiveDigest) {
          throw const FormatException(
            'Completion archive does not match its manifest',
          );
        }
        final loaded = CompletionIndex.fromZip(bytes);
        if (loaded.count != count) {
          throw const FormatException('Completion record count mismatch');
        }
        if (sha256.convert(loaded.bytes).toString() != digest) {
          throw const FormatException('Completion index checksum mismatch');
        }
        index = loaded;
        replies.send(['ready']);
        if (cache != null) {
          File? temporary;
          try {
            await cache.parent.create(recursive: true);
            temporary = File(
              '${cache.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
            );
            await temporary.writeAsBytes(loaded.bytes, flush: true);
            await temporary.rename(cache.path);
            // Remove old generations and abandoned writes. Recent temporary
            // files may belong to another live service and are left alone.
            await for (final entry in cache.parent.list()) {
              final name = entry.uri.pathSegments.last;
              if (entry is File &&
                  entry.path != cache.path &&
                  RegExp(
                    r'^[a-f0-9]{64}\.bin(?:\.[0-9]+\.tmp)?$',
                  ).hasMatch(name)) {
                try {
                  if (name.endsWith('.bin') ||
                      DateTime.now().difference((await entry.stat()).modified) >
                          const Duration(days: 1)) {
                    await entry.delete();
                  }
                } catch (_) {}
              }
            }
          } catch (_) {
            // A read-only/full cache is an optimization failure, not a search failure.
          } finally {
            try {
              if (temporary != null && await temporary.exists()) {
                await temporary.delete();
              }
            } catch (_) {}
          }
        }
      } catch (error) {
        replies.send(['error', error.toString()]);
      }
      return;
    }
    final id = parts[1] as int;
    try {
      if (index == null) throw StateError('Completion index is not ready');
      switch (parts[0]) {
        case 'search':
          final generation = ++searchGeneration;
          final (query, limit) = parts[2] as (String, int);
          final key = (query.toLowerCase(), limit);
          var result = searchCache.remove(key);
          if (result == null) {
            result = await index!.search(
              query,
              limit: limit,
              isCancelled: () => generation != searchGeneration,
            );
            if (generation == searchGeneration) {
              if (searchCache.length >= 64) {
                searchCache.remove(searchCache.keys.first);
              }
              searchCache[key] = result;
            }
          } else {
            searchCache[key] = result;
          }
          replies.send(['result', id, true, result]);
        case 'lookup':
          final tags = (parts[2] as List).cast<String>();
          replies.send(['result', id, true, index!.lookup(tags)]);
        default:
          throw StateError('Unknown completion operation');
      }
    } catch (error) {
      replies.send(['result', id, false, error.toString()]);
    }
  });
}
