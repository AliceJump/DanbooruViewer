import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/favorites_page.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_theme.dart';
import 'completion_normalization.dart';
import 'completion_service.dart';
import 'gallery_grid.dart';
import 'media_utils.dart';
import 'ugoira_utils.dart';

export 'completion_models.dart' show SearchCompletionSuggestion;

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
  const MyApp({super.key, this.completionService});

  final CompletionService? completionService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Danbooru Viewer',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: MyHomePage(
        title: 'Danbooru Viewer',
        completionService: completionService,
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.title,
    this.fetchPosts,
    this.completionService,
  });

  final String title;
  final Future<http.Response> Function(Uri)? fetchPosts;

  /// This page owns and disposes the supplied service, including test services.
  /// Child routes share it without taking ownership.
  final CompletionService? completionService;

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
  late final CompletionService _completionService;
  List<SearchCompletionSuggestion> _bootstrapSuggestions = [];
  Timer? _completionDebounce;
  int _completionGeneration = 0;
  String? _lastCompletionQuery;
  bool _isQueryPending = false;
  bool _updatingSearchText = false;
  final Map<String, String> _completionDisplayByInsertValue = {};
  final Map<String, int> _completionCategoryByInsertValue = {};
  final List<SearchChip> _searchChips = [];
  bool _isLoading = false;
  bool _isCompletionLoading = true;
  bool _showSuggestions = false;
  String? _bootstrapLoadError;
  String? _completionQueryError;
  int _page = 1;
  int _requestGeneration = 0;
  bool _hasMorePosts = true;

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
    _completionService = widget.completionService ?? IndexedCompletionService();
    _searchController.addListener(_refreshCompletionSuggestions);
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    _scrollController.addListener(() {
      if (_scrollController.position.pixels ==
              _scrollController.position.maxScrollExtent &&
          !_isLoading &&
          _hasMorePosts) {
        _fetchPosts(isLoadMore: true);
      }
    });
    // 启动时加载一次空搜索
    _fetchPosts();
    _loadCompletionSuggestions();
  }

  @override
  void dispose() {
    _cancelCompletionQuery();
    unawaited(_disposeCompletionService());
    _searchController.removeListener(_refreshCompletionSuggestions);
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _disposeCompletionService() async {
    try {
      await _completionService.dispose();
    } catch (e) {
      debugPrint('Failed to dispose completion service: $e');
    }
  }

  Future<void> _loadCompletionSuggestions() async {
    try {
      final candidates = await _completionService.bootstrap();
      if (!mounted) return;
      setState(() {
        _bootstrapSuggestions = candidates;
        _isCompletionLoading = false;
        _bootstrapLoadError = candidates.isEmpty ? '没有可用的标签建议' : null;
        if (_currentSearchToken().value.isEmpty) {
          _visibleSuggestions = candidates;
        }
      });
    } catch (e) {
      debugPrint('Failed to load completion bootstrap: $e');
      if (!mounted) return;
      setState(() {
        _isCompletionLoading = false;
        _bootstrapLoadError = '标签建议暂不可用，仍可直接搜索';
      });
    }
  }

  void _cancelCompletionQuery() {
    _completionDebounce?.cancel();
    _completionDebounce = null;
    _completionGeneration++;
    _lastCompletionQuery = null;
  }

  void _handleSearchFocusChanged() {
    if (!mounted) return;
    if (_searchFocusNode.hasFocus) {
      _refreshCompletionSuggestions();
    } else {
      _cancelCompletionQuery();
      setState(() {
        _showSuggestions = false;
        _isQueryPending = false;
      });
    }
  }

  void _refreshCompletionSuggestions() {
    if (!mounted || _updatingSearchText || !_searchFocusNode.hasFocus) return;
    final query = normalizeCompletionKey(_currentSearchToken().value);
    // Selection/composing notifications with the same token need no new query.
    if (query == _lastCompletionQuery) return;
    _completionDebounce?.cancel();
    final generation = ++_completionGeneration;
    _lastCompletionQuery = query;
    setState(() {
      _showSuggestions = true;
      _isQueryPending = query.isNotEmpty;
      if (query.isEmpty) {
        _visibleSuggestions = _bootstrapSuggestions;
      } else {
        _completionQueryError = null;
        // Retain only useful previous results while the indexed query runs.
        _visibleSuggestions = _visibleSuggestions.where((item) {
          return normalizeCompletionKey(item.value).contains(query) ||
              normalizeCompletionKey(item.insertValue).contains(query);
        }).toList();
      }
    });
    if (query.isEmpty) return;
    _completionDebounce = Timer(const Duration(milliseconds: 120), () {
      _completionDebounce = null;
      unawaited(_runCompletionSearch(query, generation));
    });
  }

  Future<void> _runCompletionSearch(String query, int generation) async {
    try {
      final matches = await _completionService.search(query, limit: 10);
      if (!mounted ||
          generation != _completionGeneration ||
          !_searchFocusNode.hasFocus) {
        return;
      }
      setState(() {
        _visibleSuggestions = matches;
        _isQueryPending = false;
      });
    } catch (e) {
      if (!mounted ||
          generation != _completionGeneration ||
          !_searchFocusNode.hasFocus) {
        return;
      }
      debugPrint('Failed to query completion index: $e');
      setState(() {
        _isQueryPending = false;
        _completionQueryError = '标签建议暂不可用，仍可直接搜索';
      });
    }
  }

  void _setSearchInput(String text) {
    _updatingSearchText = true;
    try {
      _searchController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } finally {
      _updatingSearchText = false;
    }
  }

  void _rememberCompletionMetadata(Map<String, CompletionTagInfo> metadata) {
    for (final entry in metadata.entries) {
      final key = normalizeCompletionKey(entry.key);
      _completionDisplayByInsertValue[key] = entry.value.label;
      final category = entry.value.category;
      if (category != null) _completionCategoryByInsertValue[key] = category;
    }
    // Only labels encountered in this session enter the UI isolate.
    while (_completionDisplayByInsertValue.length > 512) {
      final key = _completionDisplayByInsertValue.keys.first;
      _completionDisplayByInsertValue.remove(key);
      _completionCategoryByInsertValue.remove(key);
    }
  }

  Future<void> _resolveChipLabel(SearchChip chip) async {
    try {
      final metadata = await _completionService.lookup([chip.queryValue]);
      if (!mounted) return;
      _rememberCompletionMetadata(metadata);
      final index = _searchChips.indexWhere((item) => identical(item, chip));
      final label = metadata[normalizeCompletionKey(chip.queryValue)]?.label;
      if (index < 0 || label == null || label == chip.label) return;
      setState(() {
        _searchChips[index] = SearchChip(
          label: label,
          queryValue: chip.queryValue,
        );
      });
    } catch (e) {
      debugPrint('Failed to resolve search tag label: $e');
    }
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

    _cancelCompletionQuery();
    setState(() {
      _upsertSearchChip(
        SearchChip(label: suggestion.value, queryValue: suggestion.insertValue),
      );
      _setSearchInput(remainingText);
      _showSuggestions = false;
      _isQueryPending = false;
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
    _cancelCompletionQuery();
    final chip = SearchChip(label: label, queryValue: queryValue);
    setState(() {
      _upsertSearchChip(chip);
      _setSearchInput('');
      _showSuggestions = false;
      _isQueryPending = false;
    });
    _fetchPosts();
    unawaited(_resolveChipLabel(chip));
  }

  /// 回车时把输入框中的文本当作一个整体标签加入搜索。
  ///
  /// 空格不做特殊处理：整行（去除首尾空白后）作为一个标签 chip，
  /// 不按空格拆分。若命中补全数据则 chip 显示中文名，查询词仍用原文。
  void _submitSearchText(String text) {
    _cancelCompletionQuery();
    final tag = text.trim();
    if (tag.isEmpty) {
      _fetchPosts();
      return;
    }
    _addSearchChip(
      _completionDisplayByInsertValue[normalizeCompletionKey(tag)] ?? tag,
      tag,
    );
  }

  void _upsertSearchChip(SearchChip chip) {
    final normalizedQuery = normalizeCompletionKey(chip.queryValue.trim());
    if (normalizedQuery.isEmpty) return;

    _searchChips.removeWhere(
      (item) =>
          normalizeCompletionKey(item.queryValue.trim()) == normalizedQuery,
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
            if (isUgoiraUrl(imageUrl)) {
              // ugoira 动画帖：合并为 GIF 后保存
              final gifFile = await getUgoiraGifFile(imageUrl);
              await Gal.putImage(gifFile.path, album: 'danbooru_viewer');
            } else {
              final path = '${tempDir.path}/${imageUrl.split('/').last}';
              await dio.download(imageUrl, path);
              await Gal.putImage(path, album: 'danbooru_viewer');
            }
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
    if (!mounted || (isLoadMore && (_isLoading || !_hasMorePosts))) return;

    final requestGeneration = isLoadMore
        ? _requestGeneration
        : ++_requestGeneration;
    final requestPage = isLoadMore ? _page + 1 : 1;

    setState(() {
      _isLoading = true;
      if (!isLoadMore) {
        _posts = [];
        _page = 1;
        _hasMorePosts = true;
      }
    });

    if (!isLoadMore && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    try {
      List<String> ratings = getSelectedRatings();
      final queryTags = [
        ..._searchChips.map((chip) => chip.queryValue),
        ..._searchController.text.split(' ').where((s) => s.isNotEmpty),
      ];

      final tags = [
        ...queryTags,
        if (ratings.isNotEmpty) 'rating:${ratings.join(',')}',
      ].join(' ');
      final uri = Uri.https('danbooru.donmai.us', '/posts.json', {
        'tags': tags,
        'limit': '100',
        'page': '$requestPage',
      });
      final response = await (widget.fetchPosts?.call(uri) ?? http.get(uri));
      if (!mounted || requestGeneration != _requestGeneration) return;

      if (response.statusCode == 200) {
        final List<dynamic> postsJson = json.decode(response.body);
        if (postsJson.isEmpty) {
          setState(() => _hasMorePosts = false);
          return;
        }
        final newPosts = postsJson.map((json) => Post.fromJson(json)).toList();
        setState(() {
          if (isLoadMore) {
            _posts.addAll(newPosts);
          } else {
            _posts = newPosts;
          }
          _page = requestPage;
        });
      } else {
        debugPrint('Failed to load posts');
      }
    } catch (e) {
      if (mounted && requestGeneration == _requestGeneration) {
        debugPrint('Error fetching posts: $e');
      }
    } finally {
      if (mounted && requestGeneration == _requestGeneration) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _navigateToDetail(int index) async {
    if (_isMultiSelectMode) return;
    final result = await openPostDetailPage(
      context: context,
      posts: _posts,
      initialIndex: index,
      completionDisplayByValue: _completionDisplayByInsertValue,
      completionCategoryByValue: _completionCategoryByInsertValue,
      completionService: _completionService,
    );

    _handleSearchResult(result);
  }

  AppBar _buildDefaultAppBar() {
    return AppBar(
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
                  completionService: _completionService,
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
    final isEmptyQuery = _currentSearchToken().value.isEmpty;
    final isWaiting = _isQueryPending || (_isCompletionLoading && isEmptyQuery);
    final errorText = isEmptyQuery
        ? _bootstrapLoadError
        : _completionQueryError;
    final statusText = _visibleSuggestions.isNotEmpty
        ? null
        : isWaiting
        ? '正在查找标签建议...'
        : errorText ?? '没有匹配的补全建议';

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
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w500,
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
            elevation: 0,
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Text(
                          '浏览作品',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        Text(
                          '${_posts.length} 张作品',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: (_isLoading && _posts.isEmpty)
                        ? const Center(child: CircularProgressIndicator())
                        : _posts.isEmpty
                        ? const GalleryEmptyState(
                            icon: Icons.image_outlined,
                            title: '暂无结果',
                            subtitle: '试试其他标签或筛选条件',
                          )
                        : GalleryGrid(
                            controller: _scrollController,
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
