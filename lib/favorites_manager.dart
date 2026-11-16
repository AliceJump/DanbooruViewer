import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class FavoritesDataException implements Exception {
  const FavoritesDataException(this.collection);
  final String collection;

  @override
  String toString() => '$collection数据无法读取，原始数据已保留。';
}

class LegacyFavoritesRecoveryException extends FavoritesDataException {
  const LegacyFavoritesRecoveryException() : super('旧版收藏');

  @override
  String toString() => '旧版收藏仅保存作品编号，缺少作品详情。原始编号已保留，请先复制收藏备份。';
}

class FavoritesManager {
  static const String _favoritesKey = 'favorite_posts';
  static const String _favoritePostsFullKey = 'favorite_posts_full';
  static const String _favoriteTagsKey = 'favorite_tags';
  static const String _browsingHistoryKey = 'browsing_history_posts';
  static const int _maxBrowsingHistory = 200;

  // 单例模式
  static final FavoritesManager _instance = FavoritesManager._internal();
  factory FavoritesManager() => _instance;
  FavoritesManager._internal();

  FavoritesManager.forTesting(SharedPreferences preferences)
    : _prefs = preferences;

  SharedPreferences? _prefs;
  bool _needsReload = false;
  Future<void> _mutationTail = Future<void>.value();

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _mutationTail.then((_) => action());
    // The caller receives the error through result; later writes must still run.
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (_needsReload) {
      await _prefs!.reload();
      _needsReload = false;
    }
  }

  List<dynamic> _readList(String key, String collection) {
    try {
      final raw = _prefs!.getString(key);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException();
      return decoded;
    } catch (_) {
      throw FavoritesDataException(collection);
    }
  }

  List<Map<String, dynamic>> _readPosts(String key, String collection) {
    final values = _readList(key, collection);
    const textFields = [
      'rating',
      'tag_string',
      'file_url',
      'large_file_url',
      'preview_file_url',
      'tag_string_general',
      'tag_string_artist',
      'tag_string_character',
      'tag_string_copyright',
      'tag_string_meta',
      'source',
      'viewed_at',
    ];
    const numberFields = ['image_width', 'image_height'];
    final posts = <Map<String, dynamic>>[];
    for (final item in values) {
      if (item is! Map ||
          item['id'] is! int ||
          textFields.any((key) => item[key] != null && item[key] is! String) ||
          numberFields.any((key) => item[key] != null && item[key] is! int)) {
        throw FavoritesDataException(collection);
      }
      posts.add(Map<String, dynamic>.from(item));
    }
    return posts;
  }

  Future<void> _writePreference(Future<bool> Function() action) async {
    // Other settings stores can reload the shared plugin cache while this
    // write is pending. The next read must observe the committed platform
    // value, even when our write itself succeeds.
    _needsReload = true;
    try {
      if (!await action()) {
        throw StateError('本地数据保存失败，请重试。');
      }
    } catch (_) {
      // SharedPreferences updates its in-memory cache before calling the
      // platform. Never let a failed write become the next mutation's input.
      _needsReload = true;
      try {
        await _prefs!.reload();
        _needsReload = false;
      } catch (_) {
        // All future reads must reload successfully before using this cache.
      }
      rethrow;
    }
  }

  Future<void> _saveString(String key, String value) =>
      _writePreference(() => _prefs!.setString(key, value));

  Future<void> _removePreference(String key) =>
      _writePreference(() => _prefs!.remove(key));

  /// Preserve exact raw values, including damaged JSON, for recovery.
  /// This deliberately excludes network settings and cached commentary.
  Future<String> exportBackupJson() => _mutate(() async {
    await _ensureInitialized();
    // Other settings stores share this plugin cache. A backup must reflect
    // the platform, including after another store's failed write.
    _needsReload = true;
    await _prefs!.reload();
    _needsReload = false;
    const keys = [
      _favoritesKey,
      _favoritePostsFullKey,
      _favoriteTagsKey,
      _favoriteTagsV2Key,
      _browsingHistoryKey,
      'tag_blocklist_v1',
    ];
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'danbooru-viewer-raw-backup',
      'version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'values': {
        for (final key in keys)
          if (_prefs!.containsKey(key)) key: _prefs!.get(key),
      },
    });
  });

  // ========== 图片收藏功能（完整数据） ==========

  /// 获取所有收藏图片的完整数据
  Future<List<Map<String, dynamic>>> getFavoritePostsFull() =>
      _mutate(_readFavoritePostsFull);

  Future<List<Map<String, dynamic>>> _readFavoritePostsFull() async {
    await _ensureInitialized();
    if (!_prefs!.containsKey(_favoritePostsFullKey)) {
      // A nonempty legacy ID list is the only authoritative record here. It
      // cannot be replaced by an empty/full list without losing old favorites.
      final ids = await _readFavoritePostIds();
      if (ids.isNotEmpty) throw const LegacyFavoritesRecoveryException();
      return [];
    }
    return _readPosts(_favoritePostsFullKey, '收藏图片');
  }

  /// 获取所有收藏的图片ID（旧格式兼容）
  Future<List<int>> getFavoritePostIds() => _mutate(_readFavoritePostIds);

  Future<List<int>> _readFavoritePostIds() async {
    await _ensureInitialized();
    if (_prefs!.containsKey(_favoritePostsFullKey)) {
      return _readPosts(
        _favoritePostsFullKey,
        '收藏图片',
      ).map((post) => post['id'] as int).toList();
    }
    final decoded = _readList(_favoritesKey, '收藏编号');
    if (decoded.any((id) => id is! int)) {
      throw const FavoritesDataException('收藏编号');
    }
    return decoded.cast<int>();
  }

  /// 检查图片是否已收藏
  Future<bool> isFavorite(int postId) async {
    final favorites = await getFavoritePostIds();
    return favorites.contains(postId);
  }

  /// 添加收藏（存储完整数据）
  Future<void> addFavorite(Map<String, dynamic> postJson) {
    final postId = postJson['id'];
    if (postId == null) return Future<void>.value();

    return _mutate(() async {
      final fullFavorites = await _readFavoritePostsFull();
      fullFavorites.removeWhere((item) => item['id'] == postId);
      fullFavorites.insert(0, postJson);
      await _saveFavorites(fullFavorites);
    });
  }

  /// 移除收藏
  Future<void> removeFavorite(int postId) {
    return _mutate(() async {
      final fullFavorites = await _readFavoritePostsFull();
      fullFavorites.removeWhere((item) => item['id'] == postId);
      await _saveFavorites(fullFavorites);
    });
  }

  /// 切换收藏状态
  Future<bool> toggleFavorite(Map<String, dynamic> postJson) {
    final postId = postJson['id'];
    if (postId == null) return Future<bool>.value(false);
    return _mutate(() async {
      final favorites = await _readFavoritePostsFull();
      final wasFavorite = favorites.any((item) => item['id'] == postId);
      favorites.removeWhere((item) => item['id'] == postId);
      if (!wasFavorite) favorites.insert(0, postJson);
      await _saveFavorites(favorites);
      return !wasFavorite;
    });
  }

  Future<void> _saveFavorites(List<Map<String, dynamic>> favorites) async {
    final idList = favorites.map((e) => e['id'] as int).toList();
    await _saveFavoritePostsFull(favorites);
    try {
      // Full records are authoritative. A legacy mirror failure must not
      // report a committed toggle as failed and invite a reversing retry.
      await _saveFavoriteIds(idList);
    } catch (_) {
      // IDs are derived from full records on the next read.
    }
  }

  Future<void> _saveFavoritePostsFull(
    List<Map<String, dynamic>> favorites,
  ) async {
    await _ensureInitialized();
    await _saveString(_favoritePostsFullKey, jsonEncode(favorites));
  }

  Future<void> _saveFavoriteIds(List<int> ids) async {
    await _ensureInitialized();
    await _saveString(_favoritesKey, jsonEncode(ids));
  }

  // ========== 标签收藏功能 ==========

  /// 收藏标签的存储格式：
  /// - 新格式：`[{"tag": "name", "category": 4}, ...]`（带分类）
  /// - 旧格式：`["name", ...]`（纯字符串，兼容读取）
  static const String _favoriteTagsV2Key = 'favorite_tags_v2';

  /// 获取所有收藏的标签（纯标签名列表）。
  Future<List<String>> getFavoriteTags() async {
    final entries = await getFavoriteTagEntries();
    return entries.map((e) => e['tag'] as String).toList();
  }

  /// 获取所有收藏的标签条目（含分类），兼容旧格式。
  Future<List<Map<String, dynamic>>> getFavoriteTagEntries() =>
      _mutate(_readFavoriteTagEntries);

  Future<List<Map<String, dynamic>>> _readFavoriteTagEntries() async {
    await _ensureInitialized();

    // 优先读新格式
    if (_prefs!.containsKey(_favoriteTagsV2Key)) {
      final decoded = _readList(_favoriteTagsV2Key, '收藏标签');
      final entries = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is! Map ||
            item['tag'] is! String ||
            (item['tag'] as String).trim().isEmpty ||
            (item['category'] != null && item['category'] is! int)) {
          throw const FavoritesDataException('收藏标签');
        }
        entries.add(Map<String, dynamic>.from(item));
      }
      return entries;
    }

    // 旧格式：纯字符串列表，迁移为带分类条目（category 由调用方补全）
    if (!_prefs!.containsKey(_favoriteTagsKey)) return [];
    final decoded = _readList(_favoriteTagsKey, '收藏标签');
    if (decoded.any((tag) => tag is! String || tag.trim().isEmpty)) {
      throw const FavoritesDataException('收藏标签');
    }
    final entries = decoded
        .cast<String>()
        .map((tag) => <String, dynamic>{'tag': tag})
        .toList();
    // 迁移到新格式存储
    await _saveFavoriteTagEntries(entries);
    return entries;
  }

  /// 检查标签是否已收藏
  Future<bool> isTagFavorite(String tag) async {
    final favorites = await getFavoriteTags();
    return favorites.contains(tag);
  }

  /// 添加标签收藏（可带分类）。
  Future<void> addFavoriteTag(String tag, {int? category}) {
    return _mutate(() async {
      final entries = await _readFavoriteTagEntries();
      final exists = entries.any((e) => e['tag'] == tag);
      if (!exists) {
        entries.add({'tag': tag, if (category != null) 'category': category});
        await _saveFavoriteTagEntries(entries);
      }
    });
  }

  /// 只补全尚无分类的收藏标签；保留请求等待期间新保存的分类。
  Future<void> updateFavoriteTagCategory(String tag, int category) {
    return _mutate(() async {
      final entries = await _readFavoriteTagEntries();
      var changed = false;
      for (final entry in entries) {
        if (entry['tag'] == tag && entry['category'] == null) {
          entry['category'] = category;
          changed = true;
        }
      }
      if (changed) {
        await _saveFavoriteTagEntries(entries);
      }
    });
  }

  /// 移除标签收藏
  Future<void> removeFavoriteTag(String tag) {
    return _mutate(() async {
      final entries = await _readFavoriteTagEntries();
      entries.removeWhere((e) => e['tag'] == tag);
      await _saveFavoriteTagEntries(entries);
    });
  }

  /// 切换标签收藏状态
  Future<bool> toggleFavoriteTag(String tag, {int? category}) {
    return _mutate(() async {
      final entries = await _readFavoriteTagEntries();
      final wasFavorite = entries.any((e) => e['tag'] == tag);
      if (wasFavorite) {
        entries.removeWhere((e) => e['tag'] == tag);
      } else {
        entries.add({'tag': tag, if (category != null) 'category': category});
      }
      await _saveFavoriteTagEntries(entries);
      return !wasFavorite;
    });
  }

  Future<void> _saveFavoriteTagEntries(
    List<Map<String, dynamic>> entries,
  ) async {
    await _ensureInitialized();
    await _saveString(_favoriteTagsV2Key, jsonEncode(entries));
  }

  Future<List<Map<String, dynamic>>> getBrowsingHistory() =>
      _mutate(_readBrowsingHistory);

  Future<List<Map<String, dynamic>>> _readBrowsingHistory() async {
    await _ensureInitialized();
    return _readPosts(_browsingHistoryKey, '浏览历史');
  }

  Future<void> addBrowsingHistory(Map<String, dynamic> postJson) {
    final postId = postJson['id'];
    if (postId == null) return Future<void>.value();

    return _mutate(() async {
      final history = await _readBrowsingHistory();
      history.removeWhere((item) => item['id'] == postId);
      history.insert(0, {
        ...postJson,
        'viewed_at': DateTime.now().toIso8601String(),
      });

      await _saveBrowsingHistory(history.take(_maxBrowsingHistory).toList());
    });
  }

  Future<void> clearBrowsingHistory() {
    return _mutate(() async {
      await _ensureInitialized();
      await _removePreference(_browsingHistoryKey);
    });
  }

  Future<void> _saveBrowsingHistory(List<Map<String, dynamic>> history) async {
    await _ensureInitialized();
    await _saveString(_browsingHistoryKey, jsonEncode(history));
  }

  // ========== 分享简介缓存 ==========
  // 分享时用到的艺术家简介（title + description）。
  // 在拉图时顺带拉取并持久化，分享时直接读取缓存，不再发网络请求。

  static String _commentaryKey(int postId) => 'post_commentary_$postId';

  /// 读取缓存的简介；未缓存过返回 null。
  Future<String?> getCachedCommentary(int postId) => _mutate(() async {
    await _ensureInitialized();
    return _prefs!.getString(_commentaryKey(postId));
  });

  /// 保存简介到缓存。
  Future<void> setCachedCommentary(int postId, String intro) =>
      _mutate(() async {
        await _ensureInitialized();
        await _saveString(_commentaryKey(postId), intro);
      });

  /// 清空所有收藏（用于测试或重置）
  Future<void> clearAllFavorites() {
    return _mutate(() async {
      await _ensureInitialized();
      await _removePreference(_favoritesKey);
      await _removePreference(_favoritePostsFullKey);
      await _removePreference(_favoriteTagsKey);
      await _removePreference(_favoriteTagsV2Key);
      await _removePreference(_browsingHistoryKey);
    });
  }
}
