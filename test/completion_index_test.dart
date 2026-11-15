import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/completion_index.dart';
import 'package:danbooru_viewer/completion_models.dart';
import 'package:flutter_test/flutter_test.dart';

// The binary fixture is generated from completion_candidates.json by
// scripts/build_completion_index.py's normalize_candidates and pack_index.
// Using a Python-generated fixture checks the producer/consumer contract,
// especially Python's different default Unicode lowercasing behavior.
void main() {
  late Uint8List binary;
  late CompletionIndex index;
  late List<SearchCompletionSuggestion> legacy;

  setUpAll(() {
    binary = File('test/fixtures/completion_index.bin').readAsBytesSync();
    index = CompletionIndex(binary);
    legacy = _legacyCandidates(
      jsonDecode(
            File('test/fixtures/completion_candidates.json').readAsStringSync(),
          )
          as List<dynamic>,
    );
  });

  test(
    'opens the producer format and keeps the legacy deduplication result',
    () {
      expect(index.count, legacy.length);
      expect(index.count, 192);
      expect([
        for (var id = 0; id < index.count; id++) _record(index.suggestion(id)),
      ], legacy.map(_record).toList());
      final alpha = legacy.singleWhere(
        (candidate) => candidate.value == 'alpha',
      );
      expect(alpha.source, 'fixture');
      expect(alpha.category, 0);
    },
  );

  test('opens the compressed binary fixture with identical results', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('completion_index.bin', binary.length, binary));
    final compressed = CompletionIndex.fromZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    expect(compressed.count, index.count);
    expect(
      (await compressed.search('alpha')).map(_record).toList(),
      (await index.search('alpha')).map(_record).toList(),
    );
  });

  test(
    'matches the previous full scan across prefix, infix and aliases',
    () async {
      for (final query in [
        '',
        'a',
        'alpha',
        'ALPHA',
        'needle',
        'need',
        'blue',
        '蓝',
        '发',
        'Hair',
        'İ',
        'istan',
        'Σ',
        'ΟΣ',
        'οσ',
        'greekσ',
        '𐐀',
        '𐐨',
        'Name',
        'aa',
        'prefix_',
        'prefix_159',
        '_159',
        'space_tag',
        ' ',
        'there_is_no_such_fixture_tag',
        'cde',
        'tailhead',
      ]) {
        expect(
          (await index.search(query)).map(_record).toList(),
          _legacySearch(legacy, query).map(_record).toList(),
          reason: 'query: ${jsonEncode(query)}',
        );
      }
    },
  );

  test('match position outranks score and considers both fields', () async {
    final matches = await index.search('needle');
    expect(matches.map((candidate) => candidate.value), [
      'xxneedle_alias', // The insert value starts with needle.
      'needle_low', // A prefix beats even the highest-scored infix.
      'label_without_match', // Its insert value matches at position 1.
      'xneedle_high',
      '中needle',
      'xxneedle_highest',
      '😀needle',
      '𐐀needle',
      'abneedle',
      'a😀needle',
    ]);
  });

  test(
    'ranks UTF-16 positions rather than UTF-8 bytes or code points',
    () async {
      final values = (await index.search(
        'needle',
      )).map((candidate) => candidate.value).toList();
      // 中 is three UTF-8 bytes but one UTF-16 code unit. Astral characters
      // occupy two UTF-16 code units, just like the old String.indexOf ranking.
      expect(values.indexOf('中needle'), lessThan(values.indexOf('😀needle')));
      expect(values.indexOf('𐐀needle'), lessThan(values.indexOf('abneedle')));
      expect(values.indexOf('abneedle'), lessThan(values.indexOf('a😀needle')));
    },
  );

  test(
    'uses Dart simple lowercase while preserving original spellings',
    () async {
      for (final pair in [
        ('İSTAN', 'İstanbul'),
        ('οσ', 'ΟΣ'),
        ('𐐨name', '𐐀Name'),
      ]) {
        final results = await index.search(pair.$1);
        expect(results.map((candidate) => candidate.value), contains(pair.$2));
      }
      expect((await index.search('i\u0307stan')), isEmpty);
      expect((await index.search('ος')), isEmpty);
    },
  );

  test(
    'keeps all aliases and resolves metadata like the old eager maps',
    () async {
      final aliases = await index.search('blue_hair');
      expect(aliases.map((candidate) => candidate.value), [
        'blue_hair',
        'Blue Hair',
        '蓝发',
        '青髪',
      ]);
      final keys = [
        'BLUE_HAIR',
        'blue_hair',
        'SPACE_TAG',
        'NO_CATEGORY',
        'GREEKΣ',
        'İ_TAG',
        '𐐀_TAG',
        'missing',
        '',
      ];
      final metadata = index.lookup(keys);
      expect(
        metadata.map((key, info) => MapEntry(key, [info.label, info.category])),
        _legacyLookup(legacy, keys),
      );
      expect(metadata['blue_hair']!.label, '蓝发');
      // The highest-scored category is zero; it must not be treated as absent.
      expect(metadata['blue_hair']!.category, 0);
      expect(metadata['space_tag']!.label, '空格标签');
      expect(metadata['no_category']!.category, isNull);
      expect(metadata.containsKey('missing'), isFalse);
    },
  );

  test(
    'does not match across fields, adjacent records or NUL separators',
    () async {
      for (final query in ['cde', 'bc', 'tailhead', 'c\u0000d']) {
        final results = await index.search(query);
        expect(
          results.map(_record).toList(),
          _legacySearch(legacy, query).map(_record).toList(),
          reason: 'query: ${jsonEncode(query)}',
        );
      }
      expect(await index.search('c\u0000d'), isEmpty);
      expect(index.lookup(['abc\u0000def']), isEmpty);
    },
  );

  test('respects result limits and the bounded maximum', () async {
    for (final limit in [1, 3, 10, 100]) {
      expect(
        (await index.search('prefix_', limit: limit)).map(_record).toList(),
        _legacySearch(legacy, 'prefix_', limit: limit).map(_record).toList(),
      );
    }
    expect(await index.search('prefix_', limit: 1000), hasLength(100));
    expect(await index.search('', limit: 1000), hasLength(100));
    expect(await index.search('prefix_', limit: 0), isEmpty);
    expect(await index.search('prefix_', limit: -1), isEmpty);
  });

  test('returns empty results for an empty index', () async {
    final empty = CompletionIndex(_emptyBinary());
    expect(empty.count, 0);
    expect(await empty.search(''), isEmpty);
    expect(await empty.search('anything'), isEmpty);
    expect(empty.lookup(['anything']), isEmpty);
  });

  test('rejects truncated or inconsistent headers', () {
    final wrongMagic = Uint8List.fromList(binary)..[0] = 0;
    final wrongCount = Uint8List.fromList(binary);
    ByteData.sublistView(wrongCount).setUint32(8, 0xffffffff, Endian.little);
    final wrongLength = Uint8List.fromList(binary);
    ByteData.sublistView(wrongLength).setUint32(12, 0, Endian.little);
    for (final invalid in [
      Uint8List(0),
      Uint8List.fromList(binary.sublist(0, 23)),
      Uint8List.fromList(binary.sublist(0, binary.length - 1)),
      wrongMagic,
      wrongCount,
      wrongLength,
      _emptyBinary(sources: '{}'),
      _emptyBinary(sources: '[1]'),
    ]) {
      expect(() => CompletionIndex(invalid), throwsFormatException);
    }
  });
}

List<SearchCompletionSuggestion> _legacyCandidates(List<dynamic> input) {
  final unique = <String, SearchCompletionSuggestion>{};
  for (final entry in input.whereType<Map<String, dynamic>>()) {
    final candidate = SearchCompletionSuggestion.fromJson(entry);
    if (candidate.value.trim().isEmpty ||
        candidate.insertValue.trim().isEmpty) {
      continue;
    }
    final key =
        '${candidate.value.toLowerCase()}\u0000${candidate.insertValue.toLowerCase()}';
    if (!unique.containsKey(key) || candidate.score > unique[key]!.score) {
      unique[key] = candidate;
    }
  }
  return unique.values.toList()..sort((a, b) => b.score.compareTo(a.score));
}

int _legacyPosition(SearchCompletionSuggestion candidate, String query) {
  final display = candidate.value.toLowerCase().indexOf(query);
  final insert = candidate.insertValue.toLowerCase().indexOf(query);
  if (display < 0) return insert;
  if (insert < 0) return display;
  return display < insert ? display : insert;
}

List<SearchCompletionSuggestion> _legacySearch(
  List<SearchCompletionSuggestion> candidates,
  String query, {
  int limit = 10,
}) {
  final normalized = query.toLowerCase();
  if (normalized.isEmpty) return candidates.take(limit).toList();
  final matches = <(int, SearchCompletionSuggestion)>[];
  for (final candidate in candidates) {
    final position = _legacyPosition(candidate, normalized);
    if (position >= 0) matches.add((position, candidate));
  }
  matches.sort((a, b) {
    final position = a.$1.compareTo(b.$1);
    return position == 0 ? b.$2.score.compareTo(a.$2.score) : position;
  });
  return matches.take(limit).map((entry) => entry.$2).toList();
}

Map<String, List<Object?>> _legacyLookup(
  List<SearchCompletionSuggestion> candidates,
  Iterable<String> tags,
) {
  final display = <String, String>{};
  final categories = <String, int>{};
  bool nonAscii(String value) => value.runes.any((rune) => rune > 0x7f);
  for (final candidate in candidates) {
    final key = candidate.insertValue.toLowerCase();
    final label = candidate.value.trim();
    if (key.isEmpty || label.isEmpty) continue;
    final existing = display[key];
    if (existing == null || (!nonAscii(existing) && nonAscii(label))) {
      display[key] = label;
    }
    final category = candidate.category;
    if (category != null) categories.putIfAbsent(key, () => category);
  }
  return {
    for (final tag in tags)
      if (display.containsKey(tag.toLowerCase()))
        tag.toLowerCase(): [
          display[tag.toLowerCase()],
          categories[tag.toLowerCase()],
        ],
  };
}

List<Object?> _record(SearchCompletionSuggestion candidate) => [
  candidate.value,
  candidate.insertValue,
  candidate.source,
  candidate.score,
  candidate.category,
];

Uint8List _emptyBinary({String sources = '[]'}) {
  final sourceBytes = utf8.encode(sources);
  final bytes = Uint8List(24 + sourceBytes.length);
  bytes.setRange(0, 8, ascii.encode('DBTAGI01'));
  ByteData.sublistView(bytes).setUint32(20, sourceBytes.length, Endian.little);
  bytes.setRange(24, bytes.length, sourceBytes);
  return bytes;
}
