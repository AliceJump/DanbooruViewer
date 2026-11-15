// Compile with dart compile js, then run in Node with the existing binary
// fixture supplied as globalThis.completionFixtureBase64. This exercises the
// JavaScript runtime's real lowercase behavior instead of a VM-only mock.
// This standalone regression runner reports its result to the CI log.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:danbooru_viewer/completion_backend_web.dart';
import 'package:danbooru_viewer/completion_index.dart';
import 'package:danbooru_viewer/completion_normalization.dart';

@JS('completionFixtureBase64')
external JSString get _fixtureBase64;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final binary = base64Decode(_fixtureBase64.toDart);
  final index = CompletionIndex(binary);
  const cases = {
    '': '',
    'ASCII_TAG': 'ascii_tag',
    '中文': '中文',
    'İSTAN': 'istan',
    'i\u0307stan': 'i\u0307stan',
    'ΟΣ': 'οσ',
    'ος': 'ος',
    'Σ': 'σ',
    'ẞ': 'ß',
    '𐐀NAME': '𐐨name',
    '\u037f': '\u03f3',
    '\u13a0': '\uab70',
    '\u1c90': '\u10d0',
    '\u{104b0}': '\u{104d8}',
    '\u1c89': '\u1c89',
  };
  for (final entry in cases.entries) {
    final actual = normalizeCompletionKey(entry.key);
    check(actual == entry.value, 'Normalization: ${jsonEncode(entry.key)}');
    check(normalizeCompletionKey(actual) == actual, 'Non-idempotent key');
  }

  for (final pair in [
    ('İSTAN', 'İstanbul'),
    ('ΟΣ', 'ΟΣ'),
    ('𐐀NAME', '𐐀Name'),
    ('BLUE', 'blue_hair'),
    ('蓝', '蓝发'),
  ]) {
    for (final query in [pair.$1, normalizeCompletionKey(pair.$1)]) {
      final matches = await index.search(query);
      check(
        matches.any((candidate) => candidate.value == pair.$2),
        'Index search failed for ${jsonEncode(query)}',
      );
    }
  }
  final metadata = index.lookup(['İ_TAG', 'GREEKΣ', '𐐀_TAG', 'BLUE_HAIR']);
  for (final pair in [
    ('i_tag', 'İstanbul'),
    ('greekσ', 'ΟΣ'),
    ('𐐨_tag', '𐐀Name'),
    ('blue_hair', '蓝发'),
  ]) {
    check(metadata[pair.$1]?.label == pair.$2, 'Metadata key: ${pair.$1}');
    check(metadata[pair.$1]?.category == 0, 'Metadata category zero');
  }

  final archive = Uint8List.fromList(
    ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile('completion_index.bin', binary.length, binary)),
    ),
  );
  var archiveLoads = 0;
  final backend = createCompletionBackend(
    loadArchive: () async {
      archiveLoads++;
      return archive;
    },
    indexDigest: sha256.convert(binary).toString(),
    archiveDigest: sha256.convert(archive).toString(),
    expectedCount: index.count,
  );
  try {
    await backend.initialize();
    for (final pair in [('İSTAN', 'i\u0307stan'), ('ΟΣ', 'ος')]) {
      check(
        (await backend.search(pair.$1)).isNotEmpty,
        'Web search ${pair.$1}',
      );
      check(
        (await backend.search(pair.$2)).isEmpty,
        'Web cache collision: ${jsonEncode(pair.$1)} / ${jsonEncode(pair.$2)}',
      );
      check(
        (await backend.search(normalizeCompletionKey(pair.$1))).isNotEmpty,
        'Normalized UI query: ${pair.$1}',
      );
    }
    final info = await backend.lookup(['İ_TAG', 'GREEKΣ', '𐐀_TAG']);
    check(info.length == 3, 'Web metadata lookup');
    check(archiveLoads == 1, 'Unexpected archive reload');
  } finally {
    await backend.dispose();
  }
  print('Web normalization/search/lookup/cache checks passed.');
  print(
    'JS whole-string lower: ${'İSTAN'.toLowerCase()} / ${'ΟΣ'.toLowerCase()}',
  );
}
