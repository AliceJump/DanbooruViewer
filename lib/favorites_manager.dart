import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

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

  SharedPreferences? _prefs;

  Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ========== 图片收藏功能（完整数据） ==========

  /// 获取所有收藏图片的完整数据
  Future<List<Map<String, dynamic>>> getFavoritePostsFull() async {
    await _ensureInitialized();
    final jsonString = _prefs!.getString(_favoritePostsFullKey);
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded.cast<Map<String, dynamic>>();
  }

  /// 获取所有收藏的图片ID（旧格式兼容）
  Future<List<int>> getFavoritePostIds() async {
    await _ensureInitialized();
    final jsonString = _prefs!.getString(_favoritesKey);
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded.cast<int>();
  }

  /// 检查图片是否已收藏
  Future<bool> isFavorite(int postId) async {
    final favorites = await getFavoritePostsFull();
    return favorites.any((item) => item['id'] == postId);
  }

  /// 添加收藏（存储完整数据）
  Future<void> addFavorite(Map<String, dynamic> postJson) async {
    final postId = postJson['id'];
    if (postId == null) return;

    // 存储完整数据
    final fullFavorites = await getFavoritePostsFull();
    fullFavorites.removeWhere((item) => item['id'] == postId);
    fullFavorites.insert(0, postJson);
    await _saveFavoritePostsFull(fullFavorites);

    // 同时保存旧格式ID列表
    final idList = fullFavorites.map((e) => e['id'] as int).toList();
    await _saveFavoriteIds(idList);
  }

  /// 移除收藏
  Future<void> removeFavorite(int postId) async {
    // 从完整数据中移除
    final fullFavorites = await getFavoritePostsFull();
    fullFavorites.removeWhere((item) => item['id'] == postId);
    await _saveFavoritePostsFull(fullFavorites);

    // 同时从旧格式中移除
    final idList = fullFavorites.map((e) => e['id'] as int).toList();
    await _saveFavoriteIds(idList);
  }

  /// 切换收藏状态
  Future<bool> toggleFavorite(Map<String, dynamic> postJson) async {
    final postId = postJson['id'];
    final isFav = await isFavorite(postId);
    if (isFav) {
      await removeFavorite(postId);
      return false;
    } else {
      await addFavorite(postJson);
      return true;
    }
  }

  Future<void> _saveFavoritePostsFull(List<Map<String, dynamic>> favorites) async {
    await _ensureInitialized();
    await _prefs!.setString(_favoritePostsFullKey, jsonEncode(favorites));
  }

  Future<void> _saveFavoriteIds(List<int> ids) async {
    await _ensureInitialized();
    await _prefs!.setString(_favoritesKey, jsonEncode(ids));
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
  Future<List<Map<String, dynamic>>> getFavoriteTagEntries() async {
    await _ensureInitialized();

    // 优先读新格式
    final v2 = _prefs!.getString(_favoriteTagsV2Key);
    if (v2 != null) {
      final List<dynamic> decoded = jsonDecode(v2);
      return decoded
          .whereType<Map>()
          .map((item) => item.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }

    // 旧格式：纯字符串列表，迁移为带分类条目（category 由调用方补全）
    final legacy = _prefs!.getString(_favoriteTagsKey);
    if (legacy == null) return [];
    final List<dynamic> decoded = jsonDecode(legacy);
    final entries = decoded
        .whereType<String>()
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
  Future<void> addFavoriteTag(String tag, {int? category}) async {
    final entries = await getFavoriteTagEntries();
    final exists = entries.any((e) => e['tag'] == tag);
    if (!exists) {
      entries.add({
        'tag': tag,
        if (category != null) 'category': category,
      });
      await _saveFavoriteTagEntries(entries);
    }
  }

  /// 更新已收藏标签的分类（用于补全旧收藏标签的分类信息）。
  Future<void> updateFavoriteTagCategory(String tag, int category) async {
    final entries = await getFavoriteTagEntries();
    var changed = false;
    for (final entry in entries) {
      if (entry['tag'] == tag && entry['category'] != category) {
        entry['category'] = category;
        changed = true;
      }
    }
    if (changed) {
      await _saveFavoriteTagEntries(entries);
    }
  }

  /// 移除标签收藏
  Future<void> removeFavoriteTag(String tag) async {
    final entries = await getFavoriteTagEntries();
    entries.removeWhere((e) => e['tag'] == tag);
    await _saveFavoriteTagEntries(entries);
  }

  /// 切换标签收藏状态
  Future<bool> toggleFavoriteTag(String tag, {int? category}) async {
    final isFav = await isTagFavorite(tag);
    if (isFav) {
      await removeFavoriteTag(tag);
      return false;
    } else {
      await addFavoriteTag(tag, category: category);
      return true;
    }
  }

  Future<void> _saveFavoriteTagEntries(
    List<Map<String, dynamic>> entries,
  ) async {
    await _ensureInitialized();
    await _prefs!.setString(_favoriteTagsV2Key, jsonEncode(entries));
  }

  Future<List<Map<String, dynamic>>> getBrowsingHistory() async {
    await _ensureInitialized();
    final jsonString = _prefs!.getString(_browsingHistoryKey);
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded.whereType<Map>().map((item) {
      return item.map((key, value) => MapEntry(key.toString(), value));
    }).toList();
  }

  Future<void> addBrowsingHistory(Map<String, dynamic> postJson) async {
    final postId = postJson['id'];
    if (postId == null) return;

    final history = await getBrowsingHistory();
    history.removeWhere((item) => item['id'] == postId);
    history.insert(0, {
      ...postJson,
      'viewed_at': DateTime.now().toIso8601String(),
    });

    await _saveBrowsingHistory(history.take(_maxBrowsingHistory).toList());
  }

  Future<void> clearBrowsingHistory() async {
    await _ensureInitialized();
    await _prefs!.remove(_browsingHistoryKey);
  }

  Future<void> _saveBrowsingHistory(List<Map<String, dynamic>> history) async {
    await _ensureInitialized();
    await _prefs!.setString(_browsingHistoryKey, jsonEncode(history));
  }

  // ========== 分享简介缓存 ==========
  // 分享时用到的艺术家简介（title + description）。
  // 在拉图时顺带拉取并持久化，分享时直接读取缓存，不再发网络请求。

  static String _commentaryKey(int postId) => 'post_commentary_$postId';

  /// 读取缓存的简介；未缓存过返回 null。
  Future<String?> getCachedCommentary(int postId) async {
    await _ensureInitialized();
    return _prefs!.getString(_commentaryKey(postId));
  }

  /// 保存简介到缓存。
  Future<void> setCachedCommentary(int postId, String intro) async {
    await _ensureInitialized();
    await _prefs!.setString(_commentaryKey(postId), intro);
  }

  /// 清空所有收藏（用于测试或重置）
  Future<void> clearAllFavorites() async {
    await _ensureInitialized();
    await _prefs!.remove(_favoritesKey);
    await _prefs!.remove(_favoriteTagsKey);
    await _prefs!.remove(_favoriteTagsV2Key);
    await _prefs!.remove(_browsingHistoryKey);
  }
}
