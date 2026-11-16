import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'completion_normalization.dart';
import 'completion_service.dart';
import 'favorites_manager.dart';
import 'gallery_grid.dart';
import 'media_utils.dart';
import 'post_detail_page.dart';
import 'post.dart';
import 'network/app_network_service.dart';

/// Danbooru tag category display names (0=general, 1=artist, 3=copyright,
/// 4=character, 5=meta).
const Map<int, String> _favCategoryNames = {
  0: '通用',
  1: '作者',
  3: '作品',
  4: '角色',
  5: '元数据',
};

/// Preferred display order for category groups.
const List<int> _favCategoryOrder = [4, 1, 3, 0, 5];

class FavoritesPage extends StatefulWidget {
  final Map<String, String> completionDisplayByValue;
  final Map<String, int> completionCategoryByValue;
  final CompletionService? completionService;

  const FavoritesPage({
    super.key,
    this.completionDisplayByValue = const {},
    this.completionCategoryByValue = const {},
    this.completionService,
  });

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _favoritesManager = FavoritesManager();

  // ============ Data ============
  List<Map<String, dynamic>> _favoritePosts = [];
  List<String> _favoriteTags = [];
  List<Map<String, dynamic>> _browsingHistory = [];
  bool _isLoading = true;
  int _dataGeneration = 0;
  String? _loadError;
  NetworkCancelToken? _previewCancelToken;
  int _previewGeneration = 0;
  final Map<String, CompletionTagInfo> _completionMetadata = {};
  final Map<String, int> _storedCategoryByTag = {};

  // ============ 标签筛选状态 ============
  // 图片收藏页的筛选
  final TextEditingController _favFilterController = TextEditingController();
  final FocusNode _favFilterFocusNode = FocusNode();
  final List<String> _favFilterChips = [];
  List<String> _allFavTags = [];
  List<String> _favSuggestions = [];
  bool _showFavSuggestions = false;

  // 历史记录页的筛选
  final TextEditingController _histFilterController = TextEditingController();
  final FocusNode _histFilterFocusNode = FocusNode();
  final List<String> _histFilterChips = [];
  List<String> _allHistTags = [];
  List<String> _histSuggestions = [];
  bool _showHistSuggestions = false;

  // 标签页的文本筛选
  final TextEditingController _tagFilterController = TextEditingController();
  String _tagFilterText = '';

  // 标签页的分类筛选（null = 全部）
  int? _selectedTagCategory;

  // ============ 标签预览数据 ============
  final Map<String, List<Post>> _tagPreviewPosts = {};
  final Set<String> _tagPreviewLoading = {};

  // 请求失败（网络错误 / 429 限流等）的标签，刷新时会重新拉取。
  final Set<String> _tagPreviewFailed = {};

  // Keep preview concurrency bounded and space subsequent requests.
  static const Duration _previewRequestDelay = Duration(milliseconds: 300);

  // ============ 补全数据（从主页传入，通过widget.completionDisplayByValue） ============

  @override
  void initState() {
    super.initState();
    AppNetworkService.instance.addListener(_networkSettingsChanged);
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {});
      }
    });
    _tagFilterController.addListener(() {
      setState(() {
        _tagFilterText = _tagFilterController.text;
      });
    });
    _favFilterController.addListener(_onFavFilterChanged);
    _histFilterController.addListener(_onHistFilterChanged);
    _favFilterFocusNode.addListener(_onFavFilterFocusChanged);
    _histFilterFocusNode.addListener(_onHistFilterFocusChanged);
    _loadData();
  }

  @override
  void dispose() {
    _previewCancelToken?.cancel();
    AppNetworkService.instance.removeListener(_networkSettingsChanged);
    _tabController.dispose();
    _favFilterController.removeListener(_onFavFilterChanged);
    _histFilterController.removeListener(_onHistFilterChanged);
    _favFilterFocusNode.removeListener(_onFavFilterFocusChanged);
    _histFilterFocusNode.removeListener(_onHistFilterFocusChanged);
    _favFilterController.dispose();
    _favFilterFocusNode.dispose();
    _histFilterController.dispose();
    _histFilterFocusNode.dispose();
    _tagFilterController.dispose();
    super.dispose();
  }

  // ============ 补全显示标签 ============
  String _displayLabelForTag(String tag) {
    final key = normalizeCompletionKey(tag);
    return _completionMetadata[key]?.label ??
        widget.completionDisplayByValue[key] ??
        tag;
  }

  // ============ 提取 Posts 中所有唯一标签 ============
  void _extractAllTags() {
    final favSet = <String>{};
    for (final post in _favoritePosts) {
      final tagStr = post['tag_string'] as String? ?? '';
      if (tagStr.isNotEmpty) {
        favSet.addAll(tagStr.split(' ').where((t) => t.isNotEmpty));
      }
    }
    _allFavTags = favSet.toList()..sort();

    final histSet = <String>{};
    for (final post in _browsingHistory) {
      final tagStr = post['tag_string'] as String? ?? '';
      if (tagStr.isNotEmpty) {
        histSet.addAll(tagStr.split(' ').where((t) => t.isNotEmpty));
      }
    }
    _allHistTags = histSet.toList()..sort();
  }

  // ============ 收藏筛选补全逻辑 ============
  void _onFavFilterChanged() {
    final text = _favFilterController.text;
    if (text.isEmpty) {
      setState(() {
        _favSuggestions = [];
        _showFavSuggestions = false;
      });
      return;
    }
    final query = normalizeCompletionKey(text);
    setState(() {
      _favSuggestions = _allFavTags
          .where((tag) => normalizeCompletionKey(tag).contains(query))
          .take(20)
          .toList();
      _showFavSuggestions =
          _favFilterFocusNode.hasFocus && _favSuggestions.isNotEmpty;
    });
  }

  void _onFavFilterFocusChanged() {
    if (!_favFilterFocusNode.hasFocus) {
      setState(() => _showFavSuggestions = false);
    } else if (_favFilterController.text.isNotEmpty) {
      _onFavFilterChanged();
    }
  }

  // ============ 历史筛选补全逻辑 ============
  void _onHistFilterChanged() {
    final text = _histFilterController.text;
    if (text.isEmpty) {
      setState(() {
        _histSuggestions = [];
        _showHistSuggestions = false;
      });
      return;
    }
    final query = normalizeCompletionKey(text);
    setState(() {
      _histSuggestions = _allHistTags
          .where((tag) => normalizeCompletionKey(tag).contains(query))
          .take(20)
          .toList();
      _showHistSuggestions =
          _histFilterFocusNode.hasFocus && _histSuggestions.isNotEmpty;
    });
  }

  void _onHistFilterFocusChanged() {
    if (!_histFilterFocusNode.hasFocus) {
      setState(() => _showHistSuggestions = false);
    } else if (_histFilterController.text.isNotEmpty) {
      _onHistFilterChanged();
    }
  }

  void _networkSettingsChanged() {
    if (mounted) unawaited(_loadTagPreviews(force: true));
  }

  Future<void> _loadData() async {
    final generation = ++_dataGeneration;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final posts = await _favoritesManager.getFavoritePostsFull();
      final tagEntries = await _favoritesManager.getFavoriteTagEntries();
      final history = await _favoritesManager.getBrowsingHistory();
      if (!mounted || generation != _dataGeneration) return;

      final tags = <String>[];
      final storedCategories = <String, int>{};
      for (final entry in tagEntries) {
        final tag = entry['tag'] as String? ?? '';
        if (tag.isEmpty) continue;
        tags.add(tag);
        final category = entry['category'];
        if (category is int) {
          storedCategories[normalizeCompletionKey(tag)] = category;
        }
      }
      setState(() {
        _favoritePosts = posts;
        _favoriteTags = tags;
        _browsingHistory = history;
        _storedCategoryByTag
          ..clear()
          ..addAll(storedCategories);
        _extractAllTags();
      });
      unawaited(_loadCompletionMetadata(generation, tagEntries));
      unawaited(_loadTagPreviews());
    } catch (_) {
      if (mounted && generation == _dataGeneration) {
        setState(() {
          _loadError = '无法读取收藏数据。原始数据已保留，请重试。';
        });
      }
    } finally {
      if (mounted && generation == _dataGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadCompletionMetadata(
    int generation,
    List<Map<String, dynamic>> favoriteEntries,
  ) async {
    final tags = <String>{
      ..._favoriteTags,
      ..._allFavTags,
      ..._allHistTags,
    }.map(normalizeCompletionKey).toSet().toList();
    final service = widget.completionService;
    if (service != null) {
      // Bound individual replies even for a large local favorites/history set.
      for (var start = 0; start < tags.length; start += 256) {
        if (!mounted || generation != _dataGeneration) return;
        final end = start + 256 < tags.length ? start + 256 : tags.length;
        try {
          final metadata = await service.lookup(tags.sublist(start, end));
          if (!mounted || generation != _dataGeneration) return;
          setState(() => _completionMetadata.addAll(metadata));
        } catch (e) {
          debugPrint('Failed to load favorite tag metadata: $e');
        }
      }
    }
    try {
      // Preserve successful batches and caller-provided categories even when
      // another metadata lookup fails.
      for (final entry in favoriteEntries) {
        if (!mounted || generation != _dataGeneration) return;
        final tag = entry['tag'] as String? ?? '';
        if (tag.isEmpty || entry['category'] != null) continue;
        final category = _categoryForTag(tag);
        if (category == null) continue;
        await _favoritesManager.updateFavoriteTagCategory(tag, category);
        if (!mounted || generation != _dataGeneration) return;
        _storedCategoryByTag[normalizeCompletionKey(tag)] = category;
      }
    } catch (e) {
      debugPrint('Failed to migrate favorite tag categories: $e');
    }
  }

  // ============ 标签预览图加载 ============
  Future<void> _loadTagPreviews({bool force = false}) async {
    _previewCancelToken?.cancel();
    final cancelToken = NetworkCancelToken();
    _previewCancelToken = cancelToken;
    final generation = ++_previewGeneration;
    final tags = _favoriteTags.where((tag) {
      return force ||
          !_tagPreviewPosts.containsKey(tag) ||
          _tagPreviewFailed.contains(tag);
    }).toList();
    if (!mounted) return;
    setState(_tagPreviewLoading.clear);
    var next = 0;

    Future<void> worker() async {
      while (mounted &&
          generation == _previewGeneration &&
          next < tags.length) {
        final tag = tags[next++];
        setState(() {
          _tagPreviewLoading.add(tag);
          _tagPreviewFailed.remove(tag);
        });
        try {
          final uri = Uri.https('danbooru.donmai.us', '/posts.json', {
            'tags': tag,
            'limit': '8',
            'page': '1',
          });
          final response = await AppNetworkService.instance.get(
            uri,
            cancelToken: cancelToken,
            timeout: const Duration(seconds: 12),
          );
          if (!mounted || generation != _previewGeneration) return;
          if (response.statusCode == 200) {
            final List<dynamic> postsJson = json.decode(response.body);
            final posts = postsJson.map((json) => Post.fromJson(json)).toList();
            setState(() => _tagPreviewPosts[tag] = posts);
          } else {
            setState(() => _tagPreviewFailed.add(tag));
          }
        } on NetworkCancelledException {
          return;
        } catch (_) {
          if (mounted && generation == _previewGeneration) {
            setState(() => _tagPreviewFailed.add(tag));
          }
        } finally {
          if (mounted && generation == _previewGeneration) {
            setState(() => _tagPreviewLoading.remove(tag));
          }
        }
        if (next < tags.length) {
          await Future<void>.delayed(_previewRequestDelay);
        }
      }
    }

    // One stalled request cannot block every other favorite tag.
    await Future.wait([worker(), worker()]);
  }

  // ============ 本地标签筛选逻辑 ============
  List<Map<String, dynamic>> _filterPosts(
    List<Map<String, dynamic>> posts,
    List<String> filterChips,
  ) {
    if (filterChips.isEmpty) return posts;
    return posts.where((post) {
      final tagString = normalizeCompletionKey(
        post['tag_string'] as String? ?? '',
      );
      return filterChips.every((chip) {
        final query = normalizeCompletionKey(chip);
        return tagString.contains(query);
      });
    }).toList();
  }

  /// 解析标签的分类：优先用补全映射，其次用收藏条目里持久化的分类。
  int? _categoryForTag(String tag) {
    final key = normalizeCompletionKey(tag);
    return _completionMetadata[key]?.category ??
        widget.completionCategoryByValue[key] ??
        _storedCategoryByTag[key];
  }

  List<String> _getFilteredTags() {
    final query = normalizeCompletionKey(_tagFilterText);
    return _favoriteTags.where((tag) {
      // 分类过滤
      if (_selectedTagCategory != null &&
          _categoryForTag(tag) != _selectedTagCategory) {
        return false;
      }
      // 文本过滤
      if (query.isNotEmpty &&
          !normalizeCompletionKey(tag).contains(query) &&
          !normalizeCompletionKey(_displayLabelForTag(tag)).contains(query)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// 把收藏标签按分类分组，返回扁平行列表（分组头 + 标签）。
  /// 分组顺序按 [_favCategoryOrder]，未分类的归到末尾。
  List<Object> _groupedFavoriteTags() {
    final filtered = _getFilteredTags();
    final rows = <Object>[];
    final byCategory = <int?, List<String>>{};
    for (final tag in filtered) {
      final cat = _categoryForTag(tag);
      byCategory.putIfAbsent(cat, () => []).add(tag);
    }

    final ordered = [
      ..._favCategoryOrder.map((c) => c),
      ...byCategory.keys.where(
        (c) => c != null && !_favCategoryOrder.contains(c),
      ),
      null, // 未分类放最后
    ];

    for (final category in ordered) {
      final items = byCategory[category];
      if (items == null || items.isEmpty) continue;
      final name = category == null
          ? '未分类'
          : _favCategoryNames[category] ?? '分类 $category';
      rows.add(name);
      rows.addAll(items);
    }
    return rows;
  }

  /// 分类 tab 栏的单个 chip。
  Widget _buildTagCategoryChip(int? category, String label) {
    final selected = _selectedTagCategory == category;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() {
            _selectedTagCategory = category;
          });
        },
      ),
    );
  }

  // ============ 操作 ============
  Future<void> _removePost(int postId) async {
    await _favoritesManager.removeFavorite(postId);
    await _loadData();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已取消收藏')));
    }
  }

  Future<void> _removeTag(String tag) async {
    await _favoritesManager.removeFavoriteTag(tag);
    _tagPreviewPosts.remove(tag);
    _tagPreviewLoading.remove(tag);
    _tagPreviewFailed.remove(tag);
    await _loadData();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已取消收藏标签')));
    }
  }

  void _copyTag(String tag) {
    Clipboard.setData(ClipboardData(text: tag));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制标签: $tag')));
  }

  void _searchTag(String tag) {
    Navigator.pop(context, tag);
  }

  Future<void> _clearHistory() async {
    await _favoritesManager.clearBrowsingHistory();
    await _loadData();
  }

  // ============ 导航到详情页 ============
  Future<void> _navigateToDetail(
    List<Map<String, dynamic>> postMaps,
    int index,
  ) async {
    final posts = postMaps.map((m) => Post.fromJson(m)).toList();
    final result = await openPostDetailPage(
      context: context,
      posts: posts,
      initialIndex: index,
      completionDisplayByValue: widget.completionDisplayByValue,
      completionCategoryByValue: widget.completionCategoryByValue,
      completionService: widget.completionService,
    );
    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context, result);
    } else {
      await _loadData();
    }
  }

  Future<void> _navigateToDetailFromPosts(List<Post> posts, int index) async {
    final result = await openPostDetailPage(
      context: context,
      posts: posts,
      initialIndex: index,
      completionDisplayByValue: widget.completionDisplayByValue,
      completionCategoryByValue: widget.completionCategoryByValue,
      completionService: widget.completionService,
    );
    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context, result);
    } else {
      await _loadData();
    }
  }

  // ============ 添加筛选标签 ============
  void _addFavFilterChip(String tag) {
    setState(() {
      if (!_favFilterChips.contains(tag)) {
        _favFilterChips.add(tag);
        _favFilterController.clear();
        _showFavSuggestions = false;
      }
    });
  }

  void _removeFavFilterChip(int index) {
    setState(() => _favFilterChips.removeAt(index));
  }

  void _addHistFilterChip(String tag) {
    setState(() {
      if (!_histFilterChips.contains(tag)) {
        _histFilterChips.add(tag);
        _histFilterController.clear();
        _showHistSuggestions = false;
      }
    });
  }

  void _removeHistFilterChip(int index) {
    setState(() => _histFilterChips.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final tabHeight = 56 + MediaQuery.textScalerOf(context).scale(14);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(
              height: tabHeight,
              icon: const Icon(Icons.image),
              text: '图片 (${_favoritePosts.length})',
            ),
            Tab(
              height: tabHeight,
              icon: const Icon(Icons.label),
              text: '标签 (${_favoriteTags.length})',
            ),
            Tab(
              height: tabHeight,
              icon: const Icon(Icons.history),
              text: '历史 (${_browsingHistory.length})',
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? GalleryEmptyState(
                icon: Icons.warning_amber_outlined,
                title: '收藏暂时无法读取',
                subtitle: _loadError!,
                action: FilledButton(
                  onPressed: _loadData,
                  child: const Text('重试'),
                ),
              )
            : TabBarView(
                controller: _tabController,
                children: [
                  _buildPostsTab(),
                  _buildTagsTab(),
                  _buildHistoryTab(),
                ],
              ),
      ),
    );
  }

  // =====================================================
  // Tab 1: 收藏的图片 - 网格布局 + 标签筛选
  // =====================================================
  Widget _buildPostsTab() {
    final filteredPosts = _filterPosts(_favoritePosts, _favFilterChips);
    final hasSavedPosts = _favoritePosts.isNotEmpty;

    return _buildCollectionLayout(
      header: _buildSmartFilterInput(
        controller: _favFilterController,
        focusNode: _favFilterFocusNode,
        chips: _favFilterChips,
        labelText: '筛选收藏图片',
        hintText: '输入标签筛选收藏...',
        clearTooltip: '清空收藏筛选',
        onClear: () {
          setState(() => _favFilterChips.clear());
          _favFilterController.clear();
          _favFilterFocusNode.unfocus();
        },
        onAdd: _addFavFilterChip,
        onRemove: _removeFavFilterChip,
        suggestions: _favSuggestions,
        showSuggestions: _showFavSuggestions,
        onDismissSuggestions: () => setState(() => _showFavSuggestions = false),
      ),
      content: filteredPosts.isEmpty
          ? _buildEmptyState(
              icon: hasSavedPosts
                  ? Icons.filter_alt_off_outlined
                  : Icons.favorite_border,
              title: hasSavedPosts ? '没有匹配的收藏' : '还没有收藏的图片',
              subtitle: hasSavedPosts
                  ? '尝试其他标签，或清空筛选以查看全部收藏'
                  : '在图片详情页点击收藏按钮来添加收藏',
            )
          : GalleryGrid(
              itemCount: filteredPosts.length,
              itemBuilder: (context, index) {
                final post = filteredPosts[index];
                final previewUrl = post['preview_file_url'] as String?;
                final highResUrl =
                    (post['file_url'] ?? post['large_file_url']) as String?;
                final postId = post['id'] as int;
                final colors = Theme.of(context).colorScheme;

                return PostThumbnailTile(
                  previewUrl: previewUrl,
                  highResUrl: highResUrl,
                  heroTag: 'fav_post_$postId',
                  semanticLabel: '收藏作品 #$postId',
                  onTap: () => _navigateToDetail(filteredPosts, index),
                  onLongPress: () => _removePost(postId),
                  overlay: Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      tooltip: '取消收藏作品 #$postId',
                      onPressed: () => _removePost(postId),
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(48),
                        visualDensity: VisualDensity.standard,
                        tapTargetSize: MaterialTapTargetSize.padded,
                        backgroundColor: colors.surfaceContainerHighest,
                        foregroundColor: colors.onSurface,
                      ),
                      icon: const Icon(Icons.favorite, size: 20),
                    ),
                  ),
                );
              },
            ),
    );
  }

  // =====================================================
  // Tab 2: 收藏的标签 - 每个标签显示预览图 + 文本筛选
  // =====================================================
  Widget _buildTagsTab() {
    final rows = _groupedFavoriteTags();
    final hasTags = _favoriteTags.isNotEmpty;

    return _buildCollectionLayout(
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildTagCategoryChip(null, '全部'),
                for (final category in _favCategoryOrder)
                  _buildTagCategoryChip(
                    category,
                    _favCategoryNames[category] ?? '分类 $category',
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _tagFilterController,
              decoration: InputDecoration(
                labelText: '筛选收藏标签',
                hintText: '筛选标签...',
                prefixIcon: const Icon(Icons.filter_list),
                suffixIcon:
                    _tagFilterText.isNotEmpty || _selectedTagCategory != null
                    ? IconButton(
                        tooltip: '清空标签筛选',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          setState(() => _selectedTagCategory = null);
                          _tagFilterController.clear();
                          FocusScope.of(context).unfocus();
                        },
                      )
                    : null,
              ),
            ),
          ),
        ],
      ),
      content: rows.isEmpty
          ? _buildEmptyState(
              icon: hasTags ? Icons.filter_alt_off_outlined : Icons.label_off,
              title: hasTags ? '没有匹配的收藏标签' : '还没有收藏的标签',
              subtitle: hasTags ? '尝试其他标签或分类，或清空筛选查看全部标签' : '在标签列表中长按标签来收藏',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                // 分组头
                if (row is String && !_favoriteTags.contains(row)) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                    child: Text(
                      row,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  );
                }
                final tag = row as String;
                final previewPosts = _tagPreviewPosts[tag] ?? [];
                final isLoadingPreview = _tagPreviewLoading.contains(tag);

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _searchTag(tag),
                    onLongPress: () => _showTagOptions(tag),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 标签名 + 操作按钮
                          Row(
                            children: [
                              Icon(
                                Icons.label,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _displayLabelForTag(tag),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.search, size: 20),
                                visualDensity: VisualDensity.standard,
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                onPressed: () => _searchTag(tag),
                                tooltip: '搜索此标签',
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.delete,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                visualDensity: VisualDensity.standard,
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                onPressed: () => _removeTag(tag),
                                tooltip: '取消收藏标签',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // 预览图片行
                          SizedBox(
                            height: 120,
                            child: isLoadingPreview
                                ? Center(
                                    child: Text(
                                      '正在加载预览...',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                : previewPosts.isEmpty
                                ? Center(
                                    child: Text(
                                      '暂无预览',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                : ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: previewPosts.length,
                                    separatorBuilder: (context, index) =>
                                        const SizedBox(width: 8),
                                    itemBuilder: (context, idx) {
                                      final post = previewPosts[idx];
                                      final previewUrl = post.previewFileUrl;
                                      final highResUrl =
                                          post.fileUrl ?? post.largeFileUrl;
                                      return PostThumbnailTile(
                                        previewUrl: previewUrl,
                                        highResUrl: highResUrl,
                                        heroTag: 'tag_${tag}_${post.id}',
                                        semanticLabel: '作品 #${post.id}',
                                        width: 120,
                                        height: 120,
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () => _navigateToDetailFromPosts(
                                          previewPosts,
                                          idx,
                                        ),
                                        errorIconSize: 40,
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  // =====================================================
  // Tab 3: 浏览记录 - 网格布局 + 标签筛选
  // =====================================================
  Widget _buildHistoryTab() {
    final filteredHistory = _filterPosts(_browsingHistory, _histFilterChips);
    final hasHistory = _browsingHistory.isNotEmpty;

    return _buildCollectionLayout(
      header: _buildSmartFilterInput(
        controller: _histFilterController,
        focusNode: _histFilterFocusNode,
        chips: _histFilterChips,
        labelText: '筛选浏览历史',
        hintText: '输入标签筛选历史...',
        clearTooltip: '清空历史筛选',
        onClear: () {
          setState(() => _histFilterChips.clear());
          _histFilterController.clear();
          _histFilterFocusNode.unfocus();
        },
        onAdd: _addHistFilterChip,
        onRemove: _removeHistFilterChip,
        suggestions: _histSuggestions,
        showSuggestions: _showHistSuggestions,
        onDismissSuggestions: () =>
            setState(() => _showHistSuggestions = false),
        trailing: TextButton.icon(
          onPressed: hasHistory ? _clearHistory : null,
          icon: const Icon(Icons.delete_outline, size: 20),
          label: const Text('清空浏览历史'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
      ),
      content: filteredHistory.isEmpty
          ? _buildEmptyState(
              icon: hasHistory ? Icons.filter_alt_off_outlined : Icons.history,
              title: hasHistory ? '没有匹配的浏览记录' : '还没有浏览历史',
              subtitle: hasHistory ? '尝试其他标签，或清空筛选以查看全部记录' : '浏览图片后会自动记录',
            )
          : GalleryGrid(
              itemCount: filteredHistory.length,
              itemBuilder: (context, index) {
                final post = filteredHistory[index];
                final previewUrl = post['preview_file_url'] as String?;
                final highResUrl =
                    (post['file_url'] ?? post['large_file_url']) as String?;
                final postId = post['id'] as int;

                return PostThumbnailTile(
                  previewUrl: previewUrl,
                  highResUrl: highResUrl,
                  heroTag: 'hist_post_$postId',
                  semanticLabel: '浏览记录作品 #$postId',
                  onTap: () => _navigateToDetail(filteredHistory, index),
                );
              },
            ),
    );
  }

  // =====================================================
  // 通用组件
  // =====================================================

  // Keep the controls scrollable when large text or the keyboard leaves little
  // vertical space, while retaining an independently scrollable lazy gallery.
  Widget _buildCollectionLayout({
    required Widget header,
    required Widget content,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: constraints.maxHeight * 0.55,
            ),
            child: SingleChildScrollView(child: header),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  /// 补全式筛选输入框 + 标签芯片 + 建议下拉。
  Widget _buildSmartFilterInput({
    required TextEditingController controller,
    required FocusNode focusNode,
    required List<String> chips,
    required String labelText,
    required String hintText,
    required String clearTooltip,
    required VoidCallback onClear,
    required ValueChanged<String> onAdd,
    required ValueChanged<int> onRemove,
    required List<String> suggestions,
    required bool showSuggestions,
    required VoidCallback onDismissSuggestions,
    Widget? trailing,
  }) {
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: labelText,
                hintText: hintText,
                prefixIcon: const Icon(Icons.filter_list, size: 20),
                suffixIcon: controller.text.isNotEmpty || chips.isNotEmpty
                    ? IconButton(
                        tooltip: clearTooltip,
                        onPressed: onClear,
                        icon: const Icon(Icons.clear),
                      )
                    : null,
              ),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  onAdd(value.trim());
                  onDismissSuggestions();
                  focusNode.unfocus();
                }
              },
            ),
            if (chips.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: List.generate(chips.length, (index) {
                      final tag = chips[index];
                      final label = _displayLabelForTag(tag);
                      return InputChip(
                        label: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: (constraints.maxWidth - 104).clamp(
                              0.0,
                              double.infinity,
                            ),
                          ),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        tooltip: label,
                        onPressed: () => _showFilterTag(tag),
                        onDeleted: () => onRemove(index),
                        deleteButtonTooltipMessage: '移除此筛选标签',
                      );
                    }),
                  ),
                ),
              ),
            if (showSuggestions && suggestions.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: suggestions.length,
                  itemBuilder: (context, index) {
                    final tag = suggestions[index];
                    return ListTile(
                      title: Text(
                        _displayLabelForTag(tag),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        onAdd(tag);
                        onDismissSuggestions();
                        controller.clear();
                        focusNode.unfocus();
                      },
                    );
                  },
                ),
              ),
            if (trailing != null)
              Align(alignment: Alignment.centerRight, child: trailing),
          ],
        ),
      ),
    );
  }

  Future<void> _showFilterTag(String tag) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('筛选标签'),
        scrollable: true,
        content: SelectableText(_displayLabelForTag(tag)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return GalleryEmptyState(icon: icon, title: title, subtitle: subtitle);
  }

  Future<void> _showTagOptions(String tag) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                _displayLabelForTag(tag),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('搜索此标签'),
                onTap: () {
                  Navigator.pop(context, 'search');
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制标签'),
                onTap: () {
                  Navigator.pop(context, 'copy');
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '取消收藏',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () {
                  Navigator.pop(context, 'remove');
                },
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || action == null) return;
    switch (action) {
      case 'search':
        _searchTag(tag);
        break;
      case 'copy':
        _copyTag(tag);
        break;
      case 'remove':
        _removeTag(tag);
        break;
    }
  }
}
