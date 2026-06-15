import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class FavoritesManager {
  static const String _favoritesKey = 'favorite_posts';
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

  // ========== 图片收藏功能 ==========

  /// 获取所有收藏的图片ID
  Future<List<int>> getFavoritePosts() async {
    await _ensureInitialized();
    final jsonString = _prefs!.getString(_favoritesKey);
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded.cast<int>();
  }

  /// 检查图片是否已收藏
  Future<bool> isFavorite(int postId) async {
    final favorites = await getFavoritePosts();
    return favorites.contains(postId);
  }

  /// 添加收藏
  Future<void> addFavorite(int postId) async {
    final favorites = await getFavoritePosts();
    if (!favorites.contains(postId)) {
      favorites.add(postId);
      await _saveFavorites(favorites);
    }
  }

  /// 移除收藏
  Future<void> removeFavorite(int postId) async {
    final favorites = await getFavoritePosts();
    favorites.remove(postId);
    await _saveFavorites(favorites);
  }

  /// 切换收藏状态
  Future<bool> toggleFavorite(int postId) async {
    final isFav = await isFavorite(postId);
    if (isFav) {
      await removeFavorite(postId);
      return false;
    } else {
      await addFavorite(postId);
      return true;
    }
  }

  Future<void> _saveFavorites(List<int> favorites) async {
    await _ensureInitialized();
    final jsonString = jsonEncode(favorites);
    await _prefs!.setString(_favoritesKey, jsonString);
  }

  // ========== 标签收藏功能 ==========

  /// 获取所有收藏的标签
  Future<List<String>> getFavoriteTags() async {
    await _ensureInitialized();
    final jsonString = _prefs!.getString(_favoriteTagsKey);
    if (jsonString == null) return [];
    final List<dynamic> decoded = jsonDecode(jsonString);
    return decoded.cast<String>();
  }

  /// 检查标签是否已收藏
  Future<bool> isTagFavorite(String tag) async {
    final favorites = await getFavoriteTags();
    return favorites.contains(tag);
  }

  /// 添加标签收藏
  Future<void> addFavoriteTag(String tag) async {
    final favorites = await getFavoriteTags();
    if (!favorites.contains(tag)) {
      favorites.add(tag);
      await _saveFavoriteTags(favorites);
    }
  }

  /// 移除标签收藏
  Future<void> removeFavoriteTag(String tag) async {
    final favorites = await getFavoriteTags();
    favorites.remove(tag);
    await _saveFavoriteTags(favorites);
  }

  /// 切换标签收藏状态
  Future<bool> toggleFavoriteTag(String tag) async {
    final isFav = await isTagFavorite(tag);
    if (isFav) {
      await removeFavoriteTag(tag);
      return false;
    } else {
      await addFavoriteTag(tag);
      return true;
    }
  }

  Future<void> _saveFavoriteTags(List<String> tags) async {
    await _ensureInitialized();
    final jsonString = jsonEncode(tags);
    await _prefs!.setString(_favoriteTagsKey, jsonString);
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

  /// 清空所有收藏（用于测试或重置）
  Future<void> clearAllFavorites() async {
    await _ensureInitialized();
    await _prefs!.remove(_favoritesKey);
    await _prefs!.remove(_favoriteTagsKey);
    await _prefs!.remove(_browsingHistoryKey);
  }
}
