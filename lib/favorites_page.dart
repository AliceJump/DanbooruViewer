import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'favorites_manager.dart';
import 'media_utils.dart';
import 'post_detail_page.dart';
import 'main.dart';

class FavoritesPage extends StatefulWidget {
  final Map<String, String> completionDisplayByValue;

  const FavoritesPage({super.key, this.completionDisplayByValue = const {}});

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

  // ============ 标签筛选状态 ============
  // 图片收藏页的筛选
  final TextEditingController _favFilterController = TextEditingController();
  final FocusNode _favFilterFocusNode = FocusNode();
  List<String> _favFilterChips = [];
  List<String> _allFavTags = [];
  List<String> _favSuggestions = [];
  bool _showFavSuggestions = false;

  // 历史记录页的筛选
  final TextEditingController _histFilterController = TextEditingController();
  final FocusNode _histFilterFocusNode = FocusNode();
  List<String> _histFilterChips = [];
  List<String> _allHistTags = [];
  List<String> _histSuggestions = [];
  bool _showHistSuggestions = false;

  // 标签页的文本筛选
  final TextEditingController _tagFilterController = TextEditingController();
  String _tagFilterText = '';

  // ============ 标签预览数据 ============
  Map<String, List<Post>> _tagPreviewPosts = {};

  // ============ 补全数据（从主页传入，通过widget.completionDisplayByValue） ============

  @override
  void initState() {
    super.initState();
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
    return widget.completionDisplayByValue[tag.toLowerCase()] ?? tag;
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
    final query = text.toLowerCase();
    setState(() {
      _favSuggestions = _allFavTags
          .where((tag) => tag.toLowerCase().contains(query))
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
    final query = text.toLowerCase();
    setState(() {
      _histSuggestions = _allHistTags
          .where((tag) => tag.toLowerCase().contains(query))
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

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    final posts = await _favoritesManager.getFavoritePostsFull();
    final tags = await _favoritesManager.getFavoriteTags();
    final history = await _favoritesManager.getBrowsingHistory();

    if (mounted) {
      setState(() {
        _favoritePosts = posts;
        _favoriteTags = tags;
        _browsingHistory = history;
        _isLoading = false;
      });
      _extractAllTags();
      _loadTagPreviews();
    }
  }

  // ============ 标签预览图加载 ============
  Future<void> _loadTagPreviews() async {
    for (final tag in _favoriteTags) {
      if (_tagPreviewPosts.containsKey(tag)) continue;

      try {
        final response = await http.get(
          Uri.parse(
            'https://danbooru.donmai.us/posts.json?tags=$tag&limit=8&page=1',
          ),
        );
        if (response.statusCode == 200) {
          final List<dynamic> postsJson = json.decode(response.body);
          final posts = postsJson.map((json) => Post.fromJson(json)).toList();
          if (mounted) {
            setState(() {
              _tagPreviewPosts[tag] = posts;
            });
          }
        }
      } catch (e) {
        debugPrint('Failed to load tag preview for $tag: $e');
      }
    }
  }

  // ============ 本地标签筛选逻辑 ============
  List<Map<String, dynamic>> _filterPosts(
    List<Map<String, dynamic>> posts,
    List<String> filterChips,
  ) {
    if (filterChips.isEmpty) return posts;
    return posts.where((post) {
      final tagString = (post['tag_string'] as String? ?? '').toLowerCase();
      return filterChips.every((chip) {
        final query = chip.toLowerCase();
        return tagString.contains(query);
      });
    }).toList();
  }

  List<String> _getFilteredTags() {
    if (_tagFilterText.isEmpty) return _favoriteTags;
    final query = _tagFilterText.toLowerCase();
    return _favoriteTags
        .where((tag) => tag.toLowerCase().contains(query))
        .toList();
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
    );
    if (result != null && mounted) {
      Navigator.pop(context, result);
    }
  }

  Future<void> _navigateToDetailFromPosts(List<Post> posts, int index) async {
    final result = await openPostDetailPage(
      context: context,
      posts: posts,
      initialIndex: index,
      completionDisplayByValue: widget.completionDisplayByValue,
    );
    if (result != null && mounted) {
      Navigator.pop(context, result);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: const Icon(Icons.image),
              text: '图片 (${_favoritePosts.length})',
            ),
            Tab(
              icon: const Icon(Icons.label),
              text: '标签 (${_favoriteTags.length})',
            ),
            Tab(
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [_buildPostsTab(), _buildTagsTab(), _buildHistoryTab()],
            ),
    );
  }

  // =====================================================
  // Tab 1: 收藏的图片 - 网格布局 + 标签筛选
  // =====================================================
  Widget _buildPostsTab() {
    final filteredPosts = _filterPosts(_favoritePosts, _favFilterChips);

    return Column(
      children: [
        // 补全式筛选输入
        _buildSmartFilterInput(
          controller: _favFilterController,
          focusNode: _favFilterFocusNode,
          chips: _favFilterChips,
          hintText: '输入标签筛选收藏...',
          onAdd: _addFavFilterChip,
          onRemove: _removeFavFilterChip,
          suggestions: _favSuggestions,
          showSuggestions: _showFavSuggestions,
          onDismissSuggestions: () =>
              setState(() => _showFavSuggestions = false),
        ),
        // 网格
        Expanded(
          child: filteredPosts.isEmpty
              ? _buildEmptyState(
                  icon: Icons.favorite_border,
                  title: '还没有收藏的图片',
                  subtitle: '在图片详情页点击收藏按钮来添加收藏',
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4.0,
                    mainAxisSpacing: 4.0,
                  ),
                  itemCount: filteredPosts.length,
                  itemBuilder: (context, index) {
                    final post = filteredPosts[index];
                    final previewUrl = post['preview_file_url'] as String?;
                    final highResUrl =
                        (post['file_url'] ?? post['large_file_url']) as String?;
                    final postId = post['id'] as int;

                    return PostThumbnailTile(
                      previewUrl: previewUrl,
                      highResUrl: highResUrl,
                      heroTag: 'fav_post_$postId',
                      onTap: () => _navigateToDetail(filteredPosts, index),
                      onLongPress: () => _removePost(postId),
                      overlay: Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => _removePost(postId),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // =====================================================
  // Tab 2: 收藏的标签 - 每个标签显示预览图 + 文本筛选
  // =====================================================
  Widget _buildTagsTab() {
    final filteredTags = _getFilteredTags();

    return Column(
      children: [
        // 文本筛选输入
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _tagFilterController,
            decoration: InputDecoration(
              hintText: '筛选标签...',
              prefixIcon: const Icon(Icons.filter_list),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              suffixIcon: _tagFilterText.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => _tagFilterController.clear(),
                    )
                  : null,
            ),
          ),
        ),
        // 标签列表
        Expanded(
          child: filteredTags.isEmpty
              ? _buildEmptyState(
                  icon: Icons.label_off,
                  title: '还没有收藏的标签',
                  subtitle: '在标签列表中长按标签来收藏',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: filteredTags.length,
                  itemBuilder: (context, index) {
                    final tag = filteredTags[index];
                    final previewPosts = _tagPreviewPosts[tag] ?? [];

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
                                  const Icon(
                                    Icons.label,
                                    size: 18,
                                    color: Colors.amber,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      tag,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.search, size: 20),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    onPressed: () => _searchTag(tag),
                                    tooltip: '搜索此标签',
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete,
                                      size: 20,
                                      color: Colors.red,
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    onPressed: () => _removeTag(tag),
                                    tooltip: '取消收藏',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // 预览图片行
                              SizedBox(
                                height: 120,
                                child: previewPosts.isEmpty
                                    ? const Center(
                                        child: Text(
                                          '暂无预览',
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      )
                                    : ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: previewPosts.length,
                                        separatorBuilder: (context, index) =>
                                            const SizedBox(width: 8),
                                        itemBuilder: (context, idx) {
                                          final post = previewPosts[idx];
                                          final previewUrl =
                                              post.previewFileUrl;
                                          final highResUrl =
                                              post.fileUrl ?? post.largeFileUrl;
                                          return PostThumbnailTile(
                                            previewUrl: previewUrl,
                                            highResUrl: highResUrl,
                                            heroTag: 'tag_${tag}_${post.id}',
                                            width: 120,
                                            height: 120,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            onTap: () =>
                                                _navigateToDetailFromPosts(
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
        ),
      ],
    );
  }

  // =====================================================
  // Tab 3: 浏览记录 - 网格布局 + 标签筛选
  // =====================================================
  Widget _buildHistoryTab() {
    final filteredHistory = _filterPosts(_browsingHistory, _histFilterChips);

    return Column(
      children: [
        // 清空按钮 + 补全式筛选输入
        _buildSmartFilterInput(
          controller: _histFilterController,
          focusNode: _histFilterFocusNode,
          chips: _histFilterChips,
          hintText: '输入标签筛选历史...',
          onAdd: _addHistFilterChip,
          onRemove: _removeHistFilterChip,
          suggestions: _histSuggestions,
          showSuggestions: _showHistSuggestions,
          onDismissSuggestions: () =>
              setState(() => _showHistSuggestions = false),
          trailing: TextButton.icon(
            onPressed: _clearHistory,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('清空'),
          ),
        ),
        // 网格
        Expanded(
          child: filteredHistory.isEmpty
              ? _buildEmptyState(
                  icon: Icons.history,
                  title: '还没有浏览历史',
                  subtitle: '浏览图片后会自动记录',
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4.0,
                    mainAxisSpacing: 4.0,
                  ),
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
                      onTap: () => _navigateToDetail(filteredHistory, index),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // =====================================================
  // 通用组件
  // =====================================================

  /// 补全式筛选输入框 + 标签芯片 + 建议下拉
  Widget _buildSmartFilterInput({
    required TextEditingController controller,
    required FocusNode focusNode,
    required List<String> chips,
    required String hintText,
    required Function(String) onAdd,
    required Function(int) onRemove,
    required List<String> suggestions,
    required bool showSuggestions,
    required VoidCallback onDismissSuggestions,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 输入行
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      hintText: hintText,
                      prefixIcon: const Icon(Icons.filter_list, size: 20),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) {
                        onAdd(value.trim());
                        onDismissSuggestions();
                        focusNode.unfocus();
                      }
                    },
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          // 标签 chips
          if (chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: List.generate(chips.length, (index) {
                    return InputChip(
                      label: Text(
                        chips[index],
                        style: const TextStyle(fontSize: 13),
                      ),
                      onDeleted: () => onRemove(index),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    );
                  }),
                ),
              ),
            ),
          // 补全建议下拉
          if (showSuggestions && suggestions.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
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
                    dense: true,
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
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 16, color: Colors.grey)),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Future<void> _showTagOptions(String tag) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('取消收藏', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context, 'remove');
              },
            ),
          ],
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
