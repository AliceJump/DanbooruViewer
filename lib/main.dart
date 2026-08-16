import 'dart:convert';
import 'dart:isolate';

import 'package:danbooru_viewer/favorites_page.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:danbooru_viewer/tag_database.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'media_utils.dart';

void main() {
  runApp(const MyApp());
}

class Post {
  final int id;
  final String rating;
  final String tagString;
  final String? fileUrl;
  final String? largeFileUrl;
  final String? previewFileUrl;
  final String? tagStringGeneral;
  final String? tagStringArtist;
  final String? tagStringCharacter;
  final String? tagStringCopyright;
  final String? tagStringMeta;
  final String? source;
  final int? imageWidth;
  final int? imageHeight;

  Post({
    required this.id,
    required this.rating,
    required this.tagString,
    this.fileUrl,
    this.largeFileUrl,
    this.previewFileUrl,
    this.tagStringGeneral,
    this.tagStringArtist,
    this.tagStringCharacter,
    this.tagStringCopyright,
    this.tagStringMeta,
    this.source,
    this.imageWidth,
    this.imageHeight,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'],
      rating: json['rating'],
      tagString: json['tag_string'],
      fileUrl: json['file_url'],
      largeFileUrl: json['large_file_url'],
      previewFileUrl: json['preview_file_url'],
      tagStringGeneral: json['tag_string_general'],
      tagStringArtist: json['tag_string_artist'],
      tagStringCharacter: json['tag_string_character'],
      tagStringCopyright: json['tag_string_copyright'],
      tagStringMeta: json['tag_string_meta'],
      source: json['source'],
      imageWidth: json['image_width'],
      imageHeight: json['image_height'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'rating': rating,
      'tag_string': tagString,
      'file_url': fileUrl,
      'large_file_url': largeFileUrl,
      'preview_file_url': previewFileUrl,
      'tag_string_general': tagStringGeneral,
      'tag_string_artist': tagStringArtist,
      'tag_string_character': tagStringCharacter,
      'tag_string_copyright': tagStringCopyright,
      'tag_string_meta': tagStringMeta,
      'source': source,
      'image_width': imageWidth,
      'image_height': imageHeight,
    };
  }
}

class SearchCompletionSuggestion {
  final String value;
  final String insertValue;
  final String source;
  final int score;
  final int? category;

  SearchCompletionSuggestion({
    required this.value,
    required this.insertValue,
    required this.source,
    required this.score,
    this.category,
  });

  factory SearchCompletionSuggestion.fromJson(Map<String, dynamic> json) {
    return SearchCompletionSuggestion(
      value: json['value'] as String? ?? json['v'] as String? ?? '',
      insertValue:
          json['insert_value'] as String? ??
          json['i'] as String? ??
          json['value'] as String? ??
          json['v'] as String? ??
          '',
      source: json['source'] as String? ?? json['s'] as String? ?? '',
      score: json['score'] as int? ?? json['r'] as int? ?? 0,
      category: json['category'] as int?,
    );
  }
}

/// Danbooru tag category display names (0=general, 1=artist, 3=copyright,
/// 4=character, 5=meta).
const Map<int, String> _categoryNames = {
  0: '通用',
  1: '作者',
  3: '作品',
  4: '角色',
  5: '元数据',
};

/// Preferred display order for category groups.
const List<int> _categoryOrder = [4, 1, 3, 0, 5];

/// 构建 insert_value -> 显示名 / 分类 的映射（后台 isolate 使用）。
/// 返回 (显示名映射, 分类映射)。
(Map<String, String>, Map<String, int>) _buildCompletionMaps(
  List<CompletionSuggestionRow> rows,
) {
  final display = <String, String>{};
  final category = <String, int>{};
  for (final row in rows) {
    final key = row.insertValue.toLowerCase();
    final label = row.value.trim();
    if (key.isEmpty || label.isEmpty) continue;
    final existing = display[key];
    if (existing == null ||
        (!_containsNonEnglish(existing) && _containsNonEnglish(label))) {
      display[key] = label;
    }
    final cat = row.category;
    if (cat != null) {
      category.putIfAbsent(key, () => cat);
    }
  }
  return (display, category);
}

bool _containsNonEnglish(String value) {
  return value.runes.any((rune) => rune > 0x7f);
}

class _SearchToken {
  final String value;
  final int start;

  const _SearchToken({required this.value, required this.start});
}

class SearchChip {
  final String label;
  final String queryValue;

  const SearchChip({required this.label, required this.queryValue});
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Danbooru Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Danbooru Viewer'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final LayerLink _searchLayerLink = LayerLink();
  List<Post> _posts = [];
  List<SearchCompletionSuggestion> _visibleSuggestions = [];
  final Map<String, String> _completionDisplayByInsertValue = {};
  final Map<String, int> _completionCategoryByInsertValue = {};
  final List<SearchChip> _searchChips = [];
  bool _isLoading = false;
  bool _isCompletionLoading = true;
  bool _showSuggestions = false;
  String? _completionLoadError;
  int _page = 1;

  // Multi-select state
  bool _isMultiSelectMode = false;
  final Set<int> _selectedItems = {};

  Map<String, bool> ratingOptions = {
    "全年龄 (R-0)": false,
    "轻度提示 (R-12)": false,
    "青少年警告 (R-15)": false,
    "成人限制 (R-18)": false,
  };

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshCompletionSuggestions);
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    _scrollController.addListener(() {
      if (_scrollController.position.pixels ==
              _scrollController.position.maxScrollExtent &&
          !_isLoading) {
        _fetchPosts(isLoadMore: true);
      }
    });
    // 启动时加载一次空搜索
    _fetchPosts();
    _loadCompletionSuggestions();
  }

  @override
  void dispose() {
    _searchController.removeListener(_refreshCompletionSuggestions);
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadCompletionSuggestions() async {
    try {
      // 先确保数据库就绪（首启复制 227MB 只发生一次），
      // 再在后台 isolate 构建显示映射，避免阻塞 UI 线程（全量约 200 万行）。
      await TagDatabase.ensureOpened();
      final maps = await Isolate.run(() async {
        final rows = await TagDatabase.loadAll();
        return _buildCompletionMaps(rows);
      });
      if (!mounted) return;
      setState(() {
        _completionDisplayByInsertValue
          ..clear()
          ..addAll(maps.$1);
        _completionCategoryByInsertValue
          ..clear()
          ..addAll(maps.$2);
        _isCompletionLoading = false;
        _completionLoadError = null;
      });
    } catch (e) {
      debugPrint('Failed to load completion suggestions: $e');
      if (!mounted) return;
      setState(() {
        _isCompletionLoading = false;
        _visibleSuggestions = [];
        _showSuggestions = false;
        _completionLoadError = '补全资源加载失败: $e';
      });
    }
  }

  void _handleSearchFocusChanged() {
    if (!mounted) return;
    if (_searchFocusNode.hasFocus) {
      _refreshCompletionSuggestions();
      return;
    }

    setState(() {
      _showSuggestions = false;
    });
  }

  int _completionQuerySeq = 0;

  Future<void> _refreshCompletionSuggestions() async {
    if (!mounted) return;
    final token = _currentSearchToken();
    final query = token.value.toLowerCase();
    final seq = ++_completionQuerySeq;

    List<SearchCompletionSuggestion> matches;
    try {
      final rows = await TagDatabase.querySuggestions(query, limit: 10);
      if (!mounted || seq != _completionQuerySeq) return;
      final suggestions = rows
          .map(
            (r) => SearchCompletionSuggestion(
              value: r.value,
              insertValue: r.insertValue,
              source: r.source,
              score: r.score,
              category: r.category,
            ),
          )
          .toList();

      if (query.isEmpty) {
        matches = suggestions;
      } else {
        // 字串序列匹配排序：匹配位置越靠前越优先，位置相同按 score 降序。
        final best = <(int, SearchCompletionSuggestion)>[];
        for (final item in suggestions) {
          final pos = _matchPosition(item, query);
          if (pos < 0) continue;
          final entry = (pos, item);
          var insertAt = best.length;
          for (var i = 0; i < best.length; i++) {
            if (_compareCompletionEntry(entry, best[i]) < 0) {
              insertAt = i;
              break;
            }
          }
          if (insertAt < 10) {
            best.insert(insertAt, entry);
            if (best.length > 10) {
              best.removeLast();
            }
          }
        }
        matches = best.map((e) => e.$2).toList();
      }
    } catch (e) {
      debugPrint('Failed to query completion: $e');
      if (!mounted || seq != _completionQuerySeq) return;
      matches = const [];
    }

    if (!mounted || seq != _completionQuerySeq) return;
    setState(() {
      _visibleSuggestions = matches;
      _showSuggestions = _searchFocusNode.hasFocus;
    });
  }

  /// 返回 query 在候选中最早出现的位置（value 与 insertValue 取较前者），
  /// 两者都未匹配返回 -1。位置 0 表示前缀匹配，优先级最高。
  int _matchPosition(SearchCompletionSuggestion item, String query) {
    final valuePos = item.value.toLowerCase().indexOf(query);
    final insertPos = item.insertValue.toLowerCase().indexOf(query);
    if (valuePos == -1) return insertPos;
    if (insertPos == -1) return valuePos;
    return valuePos < insertPos ? valuePos : insertPos;
  }

  /// 比较两个 (位置, 候选)：位置升序，位置相同按 score 降序。
  int _compareCompletionEntry(
    (int, SearchCompletionSuggestion) a,
    (int, SearchCompletionSuggestion) b,
  ) {
    final byPos = a.$1.compareTo(b.$1);
    return byPos != 0 ? byPos : b.$2.score.compareTo(a.$2.score);
  }

  _SearchToken _currentSearchToken() {
    final text = _searchController.text;
    final cursor = _searchController.selection.baseOffset;
    final end = cursor < 0 ? text.length : cursor;
    final start = end == 0 ? 0 : text.lastIndexOf(' ', end - 1) + 1;
    return _SearchToken(value: text.substring(start, end).trim(), start: start);
  }

  void _applyCompletionSuggestion(SearchCompletionSuggestion suggestion) {
    final text = _searchController.text;
    final cursor = _searchController.selection.baseOffset;
    final end = cursor < 0 ? text.length : cursor;
    final token = _currentSearchToken();
    final prefix = text.substring(0, token.start);
    final suffix = text.substring(end);
    final remainingText = '$prefix$suffix'.trim();

    setState(() {
      _upsertSearchChip(
        SearchChip(label: suggestion.value, queryValue: suggestion.insertValue),
      );
      _searchController.value = TextEditingValue(
        text: remainingText,
        selection: TextSelection.collapsed(offset: remainingText.length),
      );
      _showSuggestions = false;
    });
    _fetchPosts();
  }

  void _removeSearchChip(int index) {
    setState(() {
      _searchChips.removeAt(index);
    });
    _fetchPosts();
  }

  void _addSearchChip(String label, String queryValue) {
    setState(() {
      _upsertSearchChip(SearchChip(label: label, queryValue: queryValue));
      _searchController.clear();
      _showSuggestions = false;
    });
    _fetchPosts();
  }

  /// 回车时把输入框中的文本当作一个整体标签加入搜索。
  ///
  /// 空格不做特殊处理：整行（去除首尾空白后）作为一个标签 chip，
  /// 不按空格拆分。若命中补全数据则 chip 显示中文名，查询词仍用原文。
  void _submitSearchText(String text) {
    final tag = text.trim();
    if (tag.isEmpty) {
      _fetchPosts();
      return;
    }

    setState(() {
      final display =
          _completionDisplayByInsertValue[tag.toLowerCase()] ?? tag;
      _upsertSearchChip(SearchChip(label: display, queryValue: tag));
      _searchController.clear();
      _showSuggestions = false;
    });
    _fetchPosts();
  }

  void _upsertSearchChip(SearchChip chip) {
    final normalizedQuery = chip.queryValue.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return;

    _searchChips.removeWhere(
      (item) => item.queryValue.trim().toLowerCase() == normalizedQuery,
    );
    _searchChips.add(chip);
  }

  void _handleSearchResult(Object? result) {
    if (!mounted) return;
    if (result is SearchChip) {
      _addSearchChip(result.label, result.queryValue);
    } else if (result is String) {
      _addSearchChip(result, result);
    }
  }

  void _enterMultiSelectMode(int postId) {
    setState(() {
      _isMultiSelectMode = true;
      _selectedItems.add(postId);
    });
  }

  void _exitMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = false;
      _selectedItems.clear();
    });
  }

  void _toggleSelection(int postId) {
    setState(() {
      if (_selectedItems.contains(postId)) {
        _selectedItems.remove(postId);
      } else {
        _selectedItems.add(postId);
      }
      if (_selectedItems.isEmpty) {
        _isMultiSelectMode = false;
      }
    });
  }

  Future<void> _batchDownload() async {
    final itemsToDownload = _selectedPosts();

    if (itemsToDownload.isEmpty) {
      _exitMultiSelectMode();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('开始下载 ${_selectedItems.length} 张图片...')),
    );

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final status = await Gal.requestAccess();
        if (!status) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('需要存储权限来保存图片')));
          return;
        }
      }

      int successCount = 0;
      final tempDir = await getTemporaryDirectory();
      final dio = Dio();

      for (final post in itemsToDownload) {
        final imageUrl = post.fileUrl ?? post.largeFileUrl;
        if (imageUrl != null) {
          try {
            final path = '${tempDir.path}/${imageUrl.split('/').last}';
            await dio.download(imageUrl, path);
            await Gal.putImage(path, album: 'danbooru_viewer');
            successCount++;
          } catch (e) {
            // Log individual download error if needed
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$successCount 张图片已保存到相册')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    } finally {
      _exitMultiSelectMode();
    }
  }

  void _batchCopyLinks() {
    final links = _selectedPosts()
        .map((post) => post.fileUrl ?? post.largeFileUrl)
        .where((url) => url != null)
        .join('\n');

    if (links.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: links));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_selectedItems.length} 个链接已复制')),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有可复制的链接')));
    }
    _exitMultiSelectMode();
  }

  List<Post> _selectedPosts() {
    final postsById = <int, Post>{};
    for (final post in _posts) {
      if (_selectedItems.contains(post.id)) {
        postsById.putIfAbsent(post.id, () => post);
      }
    }
    return postsById.values.toList();
  }

  List<String> getSelectedRatings() {
    List<String> selected = [];
    ratingOptions.forEach((key, value) {
      if (value) {
        switch (key) {
          case "全年龄 (R-0)":
            selected.add('g');
            break;
          case "轻度提示 (R-12)":
            selected.add('s');
            break;
          case "青少年警告 (R-15)":
            selected.add('q');
            break;
          case "成人限制 (R-18)":
            selected.add('e');
            break;
        }
      }
    });
    return selected;
  }

  Future<void> _fetchPosts({bool isLoadMore = false}) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    if (isLoadMore) {
      _page++;
    } else {
      _page = 1;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }

    try {
      List<String> ratings = getSelectedRatings();
      final queryTags = [
        ..._searchChips.map((chip) => chip.queryValue),
        ..._searchController.text.split(' ').where((s) => s.isNotEmpty),
      ];

      String ratingTags = ratings.isNotEmpty
          ? 'rating:${ratings.join(',')}'
          : '';
      String searchTags = queryTags.join('+');
      String finalTags = searchTags;
      if (ratingTags.isNotEmpty) {
        if (finalTags.isNotEmpty) {
          finalTags += '+$ratingTags';
        } else {
          finalTags = ratingTags;
        }
      }

      final response = await http.get(
        Uri.parse(
          'https://danbooru.donmai.us/posts.json?tags=$finalTags&limit=100&page=$_page',
        ),
      );

      if (response.statusCode == 200) {
        final List<dynamic> postsJson = json.decode(response.body);
        if (postsJson.isEmpty) {
          if (isLoadMore) {
            _page--;
          }
          return;
        }
        final newPosts = postsJson.map((json) => Post.fromJson(json)).toList();
        setState(() {
          if (isLoadMore) {
            _posts.addAll(newPosts);
          } else {
            _posts = newPosts;
          }
        });
      } else {
        if (isLoadMore) _page--;
        debugPrint('Failed to load posts');
      }
    } catch (e) {
      if (isLoadMore) _page--;
      debugPrint('Error fetching posts: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _navigateToDetail(int index) async {
    if (_isMultiSelectMode) return;
    final result = await openPostDetailPage(
      context: context,
      posts: _posts,
      initialIndex: index,
      completionDisplayByValue: _completionDisplayByInsertValue,
    );

    _handleSearchResult(result);
  }

  AppBar _buildDefaultAppBar() {
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      title: Text(widget.title),
      actions: [
        IconButton(
          icon: const Icon(Icons.favorite),
          onPressed: () async {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => FavoritesPage(
                  completionDisplayByValue: _completionDisplayByInsertValue,
                  completionCategoryByValue: _completionCategoryByInsertValue,
                ),
              ),
            );
            _handleSearchResult(result);
          },
          tooltip: '我的收藏',
        ),
      ],
    );
  }

  AppBar _buildMultiSelectAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitMultiSelectMode,
      ),
      title: Text('${_selectedItems.length} 已选择'),
      actions: [
        IconButton(icon: const Icon(Icons.download), onPressed: _batchDownload),
        IconButton(icon: const Icon(Icons.link), onPressed: _batchCopyLinks),
      ],
    );
  }

  /// 把候选按分类分组，返回扁平行列表（分组头 + 候选）。
  /// 分组顺序按 [_categoryOrder]，未分类的归到末尾。
  List<Object> _groupedCompletionRows() {
    final rows = <Object>[];
    final byCategory = <int?, List<SearchCompletionSuggestion>>{};
    for (final item in _visibleSuggestions) {
      byCategory.putIfAbsent(item.category, () => []).add(item);
    }

    final ordered = [
      ..._categoryOrder.map((c) => c),
      ...byCategory.keys.where((c) => c != null && !_categoryOrder.contains(c)),
      null, // 未分类放最后
    ];

    for (final category in ordered) {
      final items = byCategory[category];
      if (items == null || items.isEmpty) continue;
      final name = category == null
          ? '未分类'
          : _categoryNames[category] ?? '分类 $category';
      rows.add(name);
      rows.addAll(items);
    }
    return rows;
  }

  Widget _buildCompletionPanel() {
    final statusText = _isCompletionLoading
        ? '正在加载补全数据...'
        : _completionLoadError ??
              (_visibleSuggestions.isEmpty ? '没有匹配的补全建议' : null);

    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: statusText != null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  statusText,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          : Builder(
              builder: (context) {
                final rows = _groupedCompletionRows();
                return ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    if (row is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                        child: Text(
                          row,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      );
                    }
                    final suggestion = row as SearchCompletionSuggestion;
                    return ListTile(
                      dense: true,
                      title: Text(
                        suggestion.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${suggestion.source} · ${suggestion.score}',
                      ),
                      onTap: () => _applyCompletionSuggestion(suggestion),
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _buildSearchInput() {
    return CompositedTransformTarget(
      link: _searchLayerLink,
      child: InputDecorator(
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              _searchFocusNode.unfocus();
              _fetchPosts();
            },
          ),
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var index = 0; index < _searchChips.length; index++)
              InputChip(
                label: Text(_searchChips[index].label),
                onDeleted: () => _removeSearchChip(index),
              ),
            SizedBox(
              width: 180,
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                decoration: const InputDecoration.collapsed(hintText: '搜索...'),
                onTapOutside: (_) => _searchFocusNode.unfocus(),
                onSubmitted: (value) {
                  _searchFocusNode.unfocus();
                  _submitSearchText(value);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletionDropdown() {
    return Positioned(
      left: 16,
      right: 16,
      top: 0,
      child: CompositedTransformFollower(
        link: _searchLayerLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 8),
        child: TextFieldTapRegion(
          child: Material(
            color: Colors.transparent,
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: _buildCompletionPanel(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isMultiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isMultiSelectMode) {
          _exitMultiSelectMode();
        }
      },
      child: Scaffold(
        appBar: _isMultiSelectMode
            ? _buildMultiSelectAppBar()
            : _buildDefaultAppBar(),
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _searchFocusNode.unfocus(),
          child: Stack(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
                    child: _buildSearchInput(),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Row(
                      children: ratingOptions.keys.map((key) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: FilterChip(
                            label: Text(key),
                            selected: ratingOptions[key]!,
                            onSelected: (bool selected) {
                              setState(() {
                                ratingOptions[key] = selected;
                              });
                              _fetchPosts();
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  Expanded(
                    child: (_isLoading && _posts.isEmpty)
                        ? const Center(child: CircularProgressIndicator())
                        : GridView.builder(
                            controller: _scrollController,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 4.0,
                                  mainAxisSpacing: 4.0,
                                ),
                            itemCount: _posts.length,
                            itemBuilder: (context, index) {
                              final post = _posts[index];
                              final isSelected = _selectedItems.contains(
                                post.id,
                              );
                              return PostThumbnailTile(
                                previewUrl: post.previewFileUrl,
                                highResUrl: post.fileUrl ?? post.largeFileUrl,
                                heroTag: 'post_${post.id}',
                                onTap: () {
                                  if (_isMultiSelectMode) {
                                    _toggleSelection(post.id);
                                  } else {
                                    _navigateToDetail(index);
                                  }
                                },
                                onLongPress: () {
                                  if (!_isMultiSelectMode) {
                                    _enterMultiSelectMode(post.id);
                                  }
                                },
                                overlay: isSelected
                                    ? Container(
                                        color: Colors.black.withValues(
                                          alpha: 0.5,
                                        ),
                                        child: const Icon(
                                          Icons.check_circle,
                                          color: Colors.white,
                                        ),
                                      )
                                    : null,
                              );
                            },
                          ),
                  ),
                  if (_isLoading && _posts.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
              if (_showSuggestions) _buildCompletionDropdown(),
            ],
          ),
        ),
      ),
    );
  }
}
