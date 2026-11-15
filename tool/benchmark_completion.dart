// Run from the repository root with the real Git LFS assets available:
//   dart run tool/benchmark_completion.dart --output /tmp/completion-benchmark.json
// Each sample runs in a fresh process. Compare defaults to four alternating
// rounds. These desktop measurements do
// not measure Android storage, keyboard rendering, or device frame latency.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:danbooru_viewer/completion_index.dart';
import 'package:danbooru_viewer/completion_models.dart';

const _queries = <String, String>{
  'empty': '',
  'common_prefix': 'blue',
  'character_prefix': 'hatsune',
  'chinese': '初音',
  'rare_infix': 'atsune_miku',
  'underscore': '_',
  'open_parenthesis': '(',
  'close_parenthesis': ')',
  'colon': ':',
  'no_match': '__completion_benchmark_no_match_8f0b2a__',
};

const _lookupTags = [
  'blue_hair',
  'BLUE_HAIR',
  'hatsune_miku',
  '1girl',
  'original',
  '__completion_benchmark_no_match_8f0b2a__',
];

Future<void> main(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    final result = options.mode == 'compare'
        ? await _compare(options)
        : await _measure(options);
    final output = const JsonEncoder.withIndent('  ').convert(result);
    if (options.output != null) {
      File(options.output!).writeAsStringSync('$output\n');
    }
    stdout.writeln(output);
    if (result['allRunsSucceeded'] == false) exitCode = 1;
  } catch (error, stack) {
    stderr.writeln(error);
    stderr.writeln(stack);
    exitCode = 1;
  }
}

class _Options {
  final String mode;
  final String source;
  final String index;
  final String bootstrap;
  final String? cache;
  final String? output;
  final int repetitions;
  final int rounds;

  const _Options({
    this.mode = 'compare',
    this.source = 'assets/danbooru_completion.zip',
    this.index = 'assets/danbooru_completion.index.zip',
    this.bootstrap = 'assets/danbooru_completion.bootstrap.json',
    this.cache,
    this.output,
    this.repetitions = 2,
    this.rounds = 4,
  });

  factory _Options.parse(List<String> arguments) {
    final values = <String, String>{};
    const names = {
      '--mode',
      '--source',
      '--index',
      '--bootstrap',
      '--cache',
      '--output',
      '--repetitions',
      '--rounds',
    };
    for (var i = 0; i < arguments.length; i += 2) {
      if (!names.contains(arguments[i]) || i + 1 >= arguments.length) {
        throw ArgumentError('Expected --option value, got ${arguments[i]}');
      }
      values[arguments[i]] = arguments[i + 1];
    }
    final mode = values['--mode'] ?? 'compare';
    if (!{'compare', 'legacy', 'index-cold', 'index-warm'}.contains(mode)) {
      throw ArgumentError('Unknown benchmark mode: $mode');
    }
    final repetitions = int.parse(values['--repetitions'] ?? '2');
    if (repetitions < 0 || repetitions > 20) {
      throw ArgumentError('repetitions must be between 0 and 20');
    }
    final rounds = int.parse(values['--rounds'] ?? '4');
    if (rounds < 1 || rounds > 20) {
      throw ArgumentError('rounds must be between 1 and 20');
    }
    return _Options(
      mode: mode,
      source: values['--source'] ?? 'assets/danbooru_completion.zip',
      index: values['--index'] ?? 'assets/danbooru_completion.index.zip',
      bootstrap:
          values['--bootstrap'] ?? 'assets/danbooru_completion.bootstrap.json',
      cache: values['--cache'],
      output: values['--output'],
      repetitions: repetitions,
      rounds: rounds,
    );
  }
}

Future<Map<String, Object?>> _compare(_Options options) async {
  final temporary = options.cache == null
      ? Directory.systemTemp.createTempSync('completion-benchmark-')
      : null;
  final cache = options.cache ?? '${temporary!.path}/completion_index.bin';
  final rounds = <Map<String, dynamic>>[];
  try {
    for (var round = 0; round < options.rounds; round++) {
      // Alternate the legacy and index groups; each warm process must still
      // follow the cold process that writes its cache in the same round.
      final order = round.isEven
          ? ['legacy', 'index-cold', 'index-warm']
          : ['index-cold', 'index-warm', 'legacy'];
      final results = <String, dynamic>{};
      final executionOrder = <String>[];
      for (final mode in order) {
        if (mode == 'index-warm' && results['index-cold']['failed'] == true) {
          results[mode] = {
            'failed': true,
            'reason': 'The cold process did not produce a cache this round.',
          };
          continue;
        }
        executionOrder.add(mode);
        final script = Platform.script.toFilePath();
        final child = await Process.run(Platform.resolvedExecutable, [
          if (script.endsWith('.dart')) script,
          '--mode',
          mode,
          '--source',
          options.source,
          '--index',
          options.index,
          '--bootstrap',
          options.bootstrap,
          '--cache',
          cache,
          '--repetitions',
          '${options.repetitions}',
        ]);
        if (child.exitCode != 0) {
          // Retain failures and still attempt the other independent mode. An
          // OOM or failed asset check is never a successful performance sample.
          results[mode] = {
            'failed': true,
            'exitCode': child.exitCode,
            'stderr': child.stderr.toString(),
          };
        } else {
          results[mode] = jsonDecode(child.stdout as String);
        }
      }
      rounds.add({
        'round': round + 1,
        'order': executionOrder,
        'runs': results,
        'equivalence': _equivalence(results),
      });
    }
  } finally {
    temporary?.deleteSync(recursive: true);
  }

  return {
    'schemaVersion': 2,
    'generatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'description':
        'Independent desktop processes; initialization includes file reads. '
        'Cold index includes archive SHA-256, CRC-checked inflation, index '
        'SHA-256, opening and cache writing. Warm index reads and verifies the '
        'uncompressed cache. OS page cache is not flushed. Each round alternates '
        'the legacy and index groups, keeping cold before warm within the index '
        'group. Repeated queries measure the engine, not the service result '
        'cache or Android UI.',
    'tiePolicy':
        'Match position in UTF-16, then score. Equal primary ranks may select '
        'different aliases because the new index has deterministic tie order.',
    'allRunsSucceeded': rounds.every(
      (round) =>
          (round['runs'] as Map).values.every((run) => run['failed'] != true),
    ),
    'rounds': rounds,
    'summary': _summarize(rounds),
  };
}

Map<String, dynamic> _equivalence(Map<String, dynamic> results) {
  final legacy = results['legacy'] as Map<String, dynamic>;
  final equivalence = <String, dynamic>{};
  for (final mode in ['index-cold', 'index-warm']) {
    final current = results[mode] as Map<String, dynamic>;
    if (legacy['failed'] == true || current['failed'] == true) continue;
    final oldQueries = legacy['queries'] as Map<String, dynamic>;
    final newQueries = current['queries'] as Map<String, dynamic>;
    equivalence[mode] = {
      'sameCandidateCount':
          legacy['candidateCount'] == current['candidateCount'],
      'samePrimaryRanking': {
        for (final name in _queries.keys)
          name:
              jsonEncode((oldQueries[name] as Map)['primaryRanks']) ==
              jsonEncode((newQueries[name] as Map)['primaryRanks']),
      },
      'sameExactLookup':
          jsonEncode(legacy['lookupResults']) ==
          jsonEncode(current['lookupResults']),
    };
  }
  return equivalence;
}

Map<String, Object?> _summarize(List<Map<String, dynamic>> rounds) {
  final summary = <String, Object?>{};
  for (final mode in ['legacy', 'index-cold', 'index-warm']) {
    final runs = rounds
        .map((round) => (round['runs'] as Map)[mode] as Map<String, dynamic>)
        .where((run) => run['failed'] != true)
        .toList();
    summary[mode] = {
      'successfulSamples': runs.length,
      'failedSamples': rounds.length - runs.length,
      if (runs.isNotEmpty) ...{
        'initializationMilliseconds': _statistics(
          runs.map((run) => run['initializationMilliseconds'] as num),
        ),
        'rssAfterInitializationBytes': _statistics(
          runs.map((run) => run['rssAfterInitializationBytes'] as num),
        ),
        'initializationStages': {
          for (final name in (runs.first['initializationStages'] as Map).keys)
            name: _statistics(
              runs.map((run) => run['initializationStages'][name] as num),
            ),
        },
        'queries': {
          for (final name in _queries.keys)
            name: {
              'firstMilliseconds': _statistics(
                runs.map(
                  (run) => run['queries'][name]['firstMilliseconds'] as num,
                ),
              ),
            },
        },
      },
    };
  }
  return summary;
}

Map<String, num> _statistics(Iterable<num> values) {
  final sorted = values.toList()..sort();
  final middle = sorted.length ~/ 2;
  return {
    'minimum': sorted.first,
    'median': sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2,
    'maximum': sorted.last,
  };
}

Future<Map<String, Object?>> _measure(_Options options) async {
  final rssBefore = ProcessInfo.currentRss;
  final total = Stopwatch()..start();
  final stages = <String, double>{};
  T phase<T>(String name, T Function() action) {
    final watch = Stopwatch()..start();
    final value = action();
    stages[name] = watch.elapsedMicroseconds / 1000;
    return value;
  }

  CompletionIndex? compact;
  _LegacyData? legacy;
  var inputBytes = 0;
  var bootstrapBytes = 0;
  if (options.mode == 'legacy') {
    final bytes = phase(
      'archiveReadMilliseconds',
      () => File(options.source).readAsBytesSync(),
    );
    inputBytes = bytes.length;
    legacy = phase('legacyDecodeBuildMilliseconds', () => _loadLegacy(bytes));
  } else {
    final bootstrap = phase('bootstrapLoadParseMilliseconds', () {
      final file = File(options.bootstrap).readAsBytesSync();
      bootstrapBytes = file.length;
      return jsonDecode(utf8.decode(file)) as Map<String, dynamic>;
    });
    if (options.mode == 'index-cold') {
      final bytes = phase(
        'archiveReadMilliseconds',
        () => File(options.index).readAsBytesSync(),
      );
      inputBytes = bytes.length;
      phase('archiveSha256Milliseconds', () {
        _verifyDigest(bytes, bootstrap['archiveSha256'] as String, 'archive');
      });
      compact = phase(
        'inflateValidateAndOpenMilliseconds',
        () => CompletionIndex.fromZip(bytes),
      );
      phase('indexSha256Milliseconds', () {
        _verifyDigest(
          compact!.bytes,
          bootstrap['indexSha256'] as String,
          'index',
        );
      });
      if (options.cache != null) {
        phase('cacheWriteMilliseconds', () {
          final target = File(options.cache!);
          target.parent.createSync(recursive: true);
          target.writeAsBytesSync(compact!.bytes, flush: true);
        });
      }
    } else {
      if (options.cache == null) {
        throw ArgumentError('index-warm requires --cache pointing at a binary');
      }
      final bytes = phase(
        'cacheReadMilliseconds',
        () => File(options.cache!).readAsBytesSync(),
      );
      inputBytes = bytes.length;
      phase('indexSha256Milliseconds', () {
        _verifyDigest(bytes, bootstrap['indexSha256'] as String, 'index');
      });
      compact = phase('openMilliseconds', () => CompletionIndex(bytes));
    }
    if (compact!.count != bootstrap['count']) {
      throw const FormatException('Bootstrap/index count mismatch');
    }
  }
  total.stop();
  final rssAfterInitialization = ProcessInfo.currentRss;
  final peakAfterInitialization = ProcessInfo.maxRss;

  Future<List<SearchCompletionSuggestion>> search(String query) async =>
      compact != null ? compact.search(query) : legacy!.search(query);

  final queries = <String, Object?>{};
  for (final entry in _queries.entries) {
    final watch = Stopwatch()..start();
    final matches = await search(entry.value);
    watch.stop();
    final first = watch.elapsedMicroseconds / 1000;
    final repeated = <double>[];
    for (var i = 0; i < options.repetitions; i++) {
      watch
        ..reset()
        ..start();
      await search(entry.value);
      watch.stop();
      repeated.add(watch.elapsedMicroseconds / 1000);
    }
    queries[entry.key] = {
      'query': entry.value,
      'firstMilliseconds': first,
      'repeatMilliseconds': repeated,
      'primaryRanks': [
        for (final candidate in matches)
          [
            _matchPosition(candidate, entry.value.toLowerCase()),
            candidate.score,
          ],
      ],
      'results': matches.map(_record).toList(),
    };
  }
  final lookupWatch = Stopwatch()..start();
  final metadata = compact != null
      ? compact.lookup(_lookupTags)
      : legacy!.lookup(_lookupTags);
  lookupWatch.stop();

  return {
    'mode': options.mode,
    'processId': pid,
    'dartVersion': Platform.version,
    'operatingSystem': Platform.operatingSystem,
    'candidateCount': compact?.count ?? legacy!.candidates.length,
    'inputBytes': inputBytes,
    'bootstrapBytes': bootstrapBytes,
    'indexBytes': compact?.bytes.length,
    'eagerDisplayMapEntries': legacy?.display.length ?? 0,
    'eagerCategoryMapEntries': legacy?.categories.length ?? 0,
    'initializationMilliseconds': total.elapsedMicroseconds / 1000,
    'initializationStages': stages,
    'rssBeforeBytes': rssBefore,
    'rssAfterInitializationBytes': rssAfterInitialization,
    'maxRssAfterInitializationBytes': peakAfterInitialization,
    'rssAfterQueriesBytes': ProcessInfo.currentRss,
    'maxRssBytes': ProcessInfo.maxRss,
    'queries': queries,
    'lookupMilliseconds': lookupWatch.elapsedMicroseconds / 1000,
    'lookupResults': {
      for (final key in metadata.keys.toList()..sort())
        key: {
          'label': metadata[key]!.label,
          'category': metadata[key]!.category,
        },
    },
  };
}

void _verifyDigest(Uint8List bytes, String expected, String description) {
  if (sha256.convert(bytes).toString() != expected) {
    throw FormatException('Unexpected $description SHA-256');
  }
}

class _LegacyData {
  final List<SearchCompletionSuggestion> candidates;
  final Map<String, String> display;
  final Map<String, int> categories;

  const _LegacyData(this.candidates, this.display, this.categories);

  List<SearchCompletionSuggestion> search(String query) {
    final normalized = query.toLowerCase();
    if (normalized.isEmpty) return candidates.take(10).toList();
    final best = <(int, SearchCompletionSuggestion)>[];
    for (final item in candidates) {
      final position = _matchPosition(item, normalized);
      if (position < 0) continue;
      final entry = (position, item);
      var insertAt = best.length;
      for (var i = 0; i < best.length; i++) {
        final byPosition = entry.$1.compareTo(best[i].$1);
        final comparison = byPosition != 0
            ? byPosition
            : best[i].$2.score.compareTo(entry.$2.score);
        if (comparison < 0) {
          insertAt = i;
          break;
        }
      }
      if (insertAt < 10) {
        best.insert(insertAt, entry);
        if (best.length > 10) best.removeLast();
      }
    }
    return best.map((entry) => entry.$2).toList();
  }

  Map<String, CompletionTagInfo> lookup(Iterable<String> tags) => {
    for (final tag in tags)
      if (display.containsKey(tag.toLowerCase()))
        tag.toLowerCase(): CompletionTagInfo(
          label: display[tag.toLowerCase()]!,
          category: categories[tag.toLowerCase()],
        ),
  };
}

_LegacyData _loadLegacy(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final files =
      archive.files
          .where((file) => file.isFile && file.name.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  final unique = <String, SearchCompletionSuggestion>{};
  for (final file in files) {
    final payload = jsonDecode(utf8.decode(file.content as List<int>));
    final input = payload is List<dynamic>
        ? payload
        : payload is Map<String, dynamic>
        ? payload['completion_candidates'] as List<dynamic>? ?? []
        : const <dynamic>[];
    for (final row in input.whereType<Map<String, dynamic>>()) {
      final candidate = SearchCompletionSuggestion.fromJson(row);
      if (candidate.value.trim().isEmpty ||
          candidate.insertValue.trim().isEmpty) {
        continue;
      }
      final key =
          '${candidate.value.toLowerCase()}\u0000${candidate.insertValue.toLowerCase()}';
      final existing = unique[key];
      if (existing == null || candidate.score > existing.score) {
        unique[key] = candidate;
      }
    }
  }
  final candidates = unique.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  // Reproduce the old temporary records list and eager metadata maps too.
  final records = candidates
      .map((c) => (c.value, c.insertValue, c.source, c.score, c.category))
      .toList();
  final display = <String, String>{};
  final categories = <String, int>{};
  bool nonAscii(String value) => value.runes.any((rune) => rune > 0x7f);
  for (final record in records) {
    final key = record.$2.toLowerCase();
    final label = record.$1.trim();
    if (key.isEmpty || label.isEmpty) continue;
    final existing = display[key];
    if (existing == null || (!nonAscii(existing) && nonAscii(label))) {
      display[key] = label;
    }
    final category = record.$5;
    if (category != null) categories.putIfAbsent(key, () => category);
  }
  return _LegacyData(candidates, display, categories);
}

int _matchPosition(SearchCompletionSuggestion candidate, String query) {
  final display = candidate.value.toLowerCase().indexOf(query);
  final insert = candidate.insertValue.toLowerCase().indexOf(query);
  if (display < 0) return insert;
  if (insert < 0) return display;
  return display < insert ? display : insert;
}

Map<String, Object?> _record(SearchCompletionSuggestion candidate) => {
  'value': candidate.value,
  'insertValue': candidate.insertValue,
  'source': candidate.source,
  'score': candidate.score,
  'category': candidate.category,
};
