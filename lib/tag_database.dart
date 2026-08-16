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

  /// Load every completion candidate, ordered by score (descending).
  ///
  /// This mirrors the previous behavior of unpacking the whole zip into
  /// memory so search filtering keeps working exactly as before.
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
