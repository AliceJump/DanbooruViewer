import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A single completion candidate row stored in the seed database.
class CompletionSuggestionRow {
  final String value;
  final String insertValue;
  final String source;
  final int score;
  final int? category;

  const CompletionSuggestionRow({
    required this.value,
    required this.insertValue,
    required this.source,
    required this.score,
    this.category,
  });

  factory CompletionSuggestionRow.fromMap(Map<String, Object?> map) {
    return CompletionSuggestionRow(
      value: map['value'] as String? ?? '',
      insertValue: map['insert_value'] as String? ?? '',
      source: map['source'] as String? ?? '',
      score: map['score'] as int? ?? 0,
      category: map['category'] as int?,
    );
  }

  /// Convert to a plain, isolate-transferable record.
  (String, String, String, int, int?) toRecord() {
    return (value, insertValue, source, score, category);
  }

  static CompletionSuggestionRow fromRecord(
    (String, String, String, int, int?) r,
  ) {
    return CompletionSuggestionRow(
      value: r.$1,
      insertValue: r.$2,
      source: r.$3,
      score: r.$4,
      category: r.$5,
    );
  }
}

/// Read-only access to the bundled tag completion seed database.
///
/// The asset `assets/danbooru_completion.db` is read-only, so on first run it
/// is copied into the application support directory and opened via sqflite.
/// On desktop platforms (Windows/Linux/macOS) the FFI factory is used so the
/// same database file works outside mobile.
class TagDatabase {
  static const String _assetName = 'assets/danbooru_completion.db';

  static Database? _db;

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;

    // Desktop: sqflite needs the FFI factory to read a plain .db file.
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final supportDir = await getApplicationSupportDirectory();
    final dbPath = p.join(supportDir.path, 'danbooru_completion.db');

    if (!await File(dbPath).exists()) {
      final data = await rootBundle.load(_assetName);
      await File(dbPath).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    _db = await openDatabase(dbPath, readOnly: true);
    return _db!;
  }

  /// Ensure the database is opened (copies the bundled asset on first run).
  /// Call this on the UI thread before spawning background isolates so the
  /// one-time 200MB+ copy is not raced by multiple isolates.
  static Future<void> ensureOpened() async {
    await _open();
  }

  /// Query completion candidates matching [query] (case-insensitive substring
  /// match on value or insert_value), ordered by score descending.
  ///
  /// Returns at most [limit] rows. An empty query returns the top-scored rows.
  /// This is the fast path used by the search dropdown — it never loads the
  /// whole table into memory.
  static Future<List<CompletionSuggestionRow>> querySuggestions(
    String query, {
    int limit = 10,
  }) async {
    final db = await _open();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      final rows = await db.query(
        'completion_candidates',
        columns: const ['value', 'insert_value', 'source', 'score', 'category'],
        orderBy: 'score DESC',
        limit: limit,
      );
      return rows.map(CompletionSuggestionRow.fromMap).toList();
    }
    final rows = await db.query(
      'completion_candidates',
      columns: const ['value', 'insert_value', 'source', 'score', 'category'],
      where: 'value LIKE ? OR insert_value LIKE ?',
      whereArgs: ['%$q%', '%$q%'],
      orderBy: 'score DESC',
      limit: limit * 5, // fetch a bit more; caller re-sorts by match position
    );
    return rows.map(CompletionSuggestionRow.fromMap).toList();
  }

  /// Load every completion candidate, ordered by score (descending).
  ///
  /// Intended for background isolate use only (building the display-name map).
  /// Do NOT call this on the UI thread — it reads ~2M rows.
  static Future<List<CompletionSuggestionRow>> loadAll() async {
    final db = await _open();
    final rows = await db.query(
      'completion_candidates',
      columns: const ['value', 'insert_value', 'source', 'score', 'category'],
      orderBy: 'score DESC',
    );
    return rows.map(CompletionSuggestionRow.fromMap).toList();
  }

  /// Total number of candidates in the seed database (for diagnostics).
  static Future<int> count() async {
    final db = await _open();
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM completion_candidates',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  static Future<void> close() async {
    final existing = _db;
    _db = null;
    if (existing != null) {
      await existing.close();
    }
  }
}
