import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'completion_models.dart';
import 'completion_normalization.dart';

/// Immutable, build-time index. Opening it creates views over bytes, not one
/// Dart object per tag. Only selected results are decoded into strings.
class CompletionIndex {
  static const _headerSize = 24;
  static const _recordSize = 28;
  static const _sameAsSearch = 0xffffffff;

  final Uint8List bytes;
  late final ByteData _data;
  late final int count;
  late final int _valueIds;
  late final int _insertIds;
  late final int _searchStart;
  late final int _searchLength;
  late final int _originalStart;
  late final int _originalLength;
  late final List<String> _sources;

  CompletionIndex(this.bytes) {
    if (bytes.length < _headerSize ||
        ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != 'DBTAGI01') {
      throw const FormatException('Unsupported completion index');
    }
    _data = ByteData.sublistView(bytes);
    count = _u32(8);
    _searchLength = _u32(12);
    _originalLength = _u32(16);
    final sourcesLength = _u32(20);
    _valueIds = _headerSize + count * _recordSize;
    _insertIds = _valueIds + count * 4;
    _searchStart = _insertIds + count * 4;
    _originalStart = _searchStart + _searchLength;
    final sourcesStart = _originalStart + _originalLength;
    if (sourcesStart + sourcesLength != bytes.length ||
        (count > 0 && (_searchLength == 0 || _recordStart(0) != 0))) {
      throw const FormatException('Truncated completion index');
    }
    final sources = jsonDecode(utf8.decode(bytes.sublist(sourcesStart)));
    if (sources is! List || sources.any((source) => source is! String)) {
      throw const FormatException('Invalid completion sources');
    }
    _sources = sources.cast<String>();
  }

  static CompletionIndex fromZip(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final file = archive.findFile('completion_index.bin');
    if (file == null || !file.isFile) {
      throw const FormatException('Completion index missing from archive');
    }
    return CompletionIndex(file.content);
  }

  int _u32(int offset) => _data.getUint32(offset, Endian.little);
  int _row(int id) {
    if (id < 0 || id >= count) {
      throw const FormatException('Invalid completion record');
    }
    return _headerSize + id * _recordSize;
  }

  int _recordStart(int id) => _u32(_row(id));
  int _recordEnd(int id) =>
      id + 1 < count ? _recordStart(id + 1) : _searchLength;

  (int, int) _field(int id, bool insert) {
    final start = _recordStart(id);
    final end = _recordEnd(id);
    final delta = _u32(_row(id) + 4);
    if (start >= end || end > _searchLength || delta >= end - start) {
      throw const FormatException('Invalid completion string bounds');
    }
    final fieldStart = insert && delta != 0 ? start + delta : start;
    final fieldEnd = !insert && delta != 0 ? start + delta - 1 : end - 1;
    if (bytes[_searchStart + fieldEnd] != 0) {
      throw const FormatException('Unterminated completion string');
    }
    return (_searchStart + fieldStart, _searchStart + fieldEnd);
  }

  String _label(int id, bool insert) {
    final original = _u32(_row(id) + (insert ? 12 : 8));
    if (original == _sameAsSearch) {
      final (start, end) = _field(id, insert);
      return utf8.decode(Uint8List.sublistView(bytes, start, end));
    }
    if (original >= _originalLength) {
      throw const FormatException('Invalid original completion string');
    }
    final start = _originalStart + original;
    var end = start;
    final limit = _originalStart + _originalLength;
    while (end < limit && bytes[end] != 0) {
      end++;
    }
    if (end == limit) {
      throw const FormatException('Unterminated original completion string');
    }
    return utf8.decode(Uint8List.sublistView(bytes, start, end));
  }

  SearchCompletionSuggestion suggestion(int id) {
    final row = _row(id);
    final category = _data.getInt32(row + 20, Endian.little);
    final source = _u32(row + 24);
    if (source >= _sources.length) {
      throw const FormatException('Invalid completion source');
    }
    return SearchCompletionSuggestion(
      value: _label(id, false),
      insertValue: _label(id, true),
      source: _sources[source],
      score: _data.getInt32(row + 16, Endian.little),
      category: category < 0 ? null : category,
    );
  }

  int _compare(int id, bool insert, Uint8List query, bool prefix) {
    final (start, end) = _field(id, insert);
    final length = end - start;
    final common = length < query.length ? length : query.length;
    for (var i = 0; i < common; i++) {
      final difference = bytes[start + i] - query[i];
      if (difference != 0) return difference;
    }
    return prefix && length >= query.length ? 0 : length - query.length;
  }

  (int, int) _range(Uint8List query, bool insert, {bool prefix = true}) {
    final base = insert ? _insertIds : _valueIds;
    int bound(bool upper) {
      var low = 0;
      var high = count;
      while (low < high) {
        final middle = (low + high) >> 1;
        final comparison = _compare(
          _u32(base + middle * 4),
          insert,
          query,
          prefix,
        );
        if (comparison < 0 || (upper && comparison == 0)) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      return low;
    }

    return (bound(false), bound(true));
  }

  /// Prefix matches rank before all substring matches. Once the best [limit]
  /// prefix records are found, no full scan is necessary. Rare suffix queries
  /// retain the old substring semantics through a byte scan in the worker.
  Future<List<SearchCompletionSuggestion>> search(
    String query, {
    int limit = 10,
    bool Function()? isCancelled,
  }) async {
    if (limit <= 0 || count == 0) return [];
    if (limit > 100) limit = 100;
    final normalized = normalizeCompletionKey(query);
    if (normalized.contains('\u0000')) return [];
    if (normalized.isEmpty) {
      return [for (var i = 0; i < count && i < limit; i++) suggestion(i)];
    }
    final needle = Uint8List.fromList(utf8.encode(normalized));
    final best = <(int, int)>[]; // UTF-16 position, priority-ordered record ID.
    void consider(int position, int id) {
      final old = best.indexWhere((entry) => entry.$2 == id);
      if (old >= 0) {
        if (best[old].$1 <= position) return;
        best.removeAt(old);
      }
      var insertion = 0;
      while (insertion < best.length &&
          (best[insertion].$1 < position ||
              (best[insertion].$1 == position && best[insertion].$2 < id))) {
        insertion++;
      }
      if (insertion < limit) {
        best.insert(insertion, (position, id));
        if (best.length > limit) best.removeLast();
      }
    }

    for (final insert in [false, true]) {
      final (start, end) = _range(needle, insert);
      final base = insert ? _insertIds : _valueIds;
      for (var i = start; i < end; i++) {
        final id = _u32(base + i * 4);
        if (best.length < limit || id < best.last.$2) consider(0, id);
        if ((i - start + 1) % 16384 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (isCancelled?.call() ?? false) return [];
        }
      }
    }
    if (best.length < limit) {
      final shifts = List<int>.filled(256, needle.length);
      for (var i = 0; i < needle.length - 1; i++) {
        shifts[needle[i]] = needle.length - 1 - i;
      }
      final finish = _searchStart + _searchLength - needle.length;
      var cursor = _searchStart;
      var nextYield = cursor + 262144;
      var record = 0;
      while (cursor <= finish) {
        var offset = needle.length - 1;
        while (offset >= 0 && bytes[cursor + offset] == needle[offset]) {
          offset--;
        }
        if (offset < 0) {
          final relative = cursor - _searchStart;
          // Hits arrive in byte order. Nearby hits usually belong to the same
          // or next record; only sparse hits need a binary search.
          var nearby = 0;
          while (nearby < 32 &&
              record + 1 < count &&
              _recordStart(record + 1) <= relative) {
            record++;
            nearby++;
          }
          if (record + 1 < count && _recordStart(record + 1) <= relative) {
            var low = record;
            var high = count;
            while (low + 1 < high) {
              final middle = (low + high) >> 1;
              if (_recordStart(middle) <= relative) {
                low = middle;
              } else {
                high = middle;
              }
            }
            record = low;
          }
          final delta = _u32(_row(record) + 4);
          final insert = delta != 0 && relative >= _recordStart(record) + delta;
          final (fieldStart, fieldEnd) = _field(record, insert);
          if (cursor + needle.length <= fieldEnd) {
            // UTF-8 byte offsets must not change the existing Dart indexOf
            // ranking, which counts UTF-16 code units.
            var position = 0;
            for (var j = fieldStart; j < cursor; j++) {
              final byte = bytes[j];
              if (byte < 0x80 || byte >= 0xc0) position++;
              if (byte >= 0xf0) position++;
            }
            consider(position, record);
            // All position-zero matches were collected above. Once the
            // remaining slots have position one, later (lower-priority)
            // records cannot improve the result.
            if (best.length == limit &&
                best.last.$1 <= 1 &&
                record >= best.last.$2) {
              break;
            }
          }
        }
        cursor += shifts[bytes[cursor + needle.length - 1]];
        if (cursor >= nextYield) {
          await Future<void>.delayed(Duration.zero);
          if (isCancelled?.call() ?? false) return [];
          nextYield = cursor + 262144;
        }
      }
    }
    return [for (final entry in best) suggestion(entry.$2)];
  }

  /// Exact insert-value lookups decode only aliases of the requested tags.
  Map<String, CompletionTagInfo> lookup(Iterable<String> tags) {
    final result = <String, CompletionTagInfo>{};
    for (final tag in tags) {
      final key = normalizeCompletionKey(tag);
      if (key.isEmpty || key.contains('\u0000') || result.containsKey(key)) {
        continue;
      }
      final query = Uint8List.fromList(utf8.encode(key));
      final (start, end) = _range(query, true, prefix: false);
      String? label;
      var labelId = count;
      var nonEnglish = false;
      int? category;
      var categoryId = count;
      for (var i = start; i < end; i++) {
        final id = _u32(_insertIds + i * 4);
        final candidate = suggestion(id);
        final candidateLabel = candidate.value.trim();
        if (candidateLabel.isEmpty) continue;
        final localized = candidateLabel.runes.any((rune) => rune > 0x7f);
        if (label == null ||
            (localized && !nonEnglish) ||
            (localized == nonEnglish && id < labelId)) {
          label = candidateLabel;
          labelId = id;
          nonEnglish = localized;
        }
        if (candidate.category != null && id < categoryId) {
          category = candidate.category;
          categoryId = id;
        }
      }
      if (label != null) {
        result[key] = CompletionTagInfo(label: label, category: category);
      }
    }
    return result;
  }
}
