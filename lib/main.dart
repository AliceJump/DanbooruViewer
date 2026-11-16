import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/favorites_page.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_theme.dart';
import 'post.dart';
import 'completion_normalization.dart';
import 'completion_service.dart';
import 'gallery_controls.dart';
import 'gallery_grid.dart';
import 'download_progress_dialog.dart';
import 'media_utils.dart';
import 'network/app_network_service.dart';
import 'network/network_settings_page.dart';

export 'completion_models.dart' show SearchCompletionSuggestion;
export 'post.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppNetworkService.instance.initialize();
  runApp(const MyApp());
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
  final FocusNode _pageFocusNode = FocusNode(debugLabel: 'gallery');
  final ScrollController _scrollController = ScrollController();
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
  String _activeQueryTags = '';
  String? _postsError;
  bool _failedLoadMore = false;
  NetworkCancelToken? _postsCancelToken;
  bool _isDownloading = false;

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
    AppNetworkService.instance.addListener(_networkSettingsChanged);
    _searchController.addListener(_refreshCompletionSuggestions);
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    _scrollController.addListener(() {
      if (_scrollController.position.pixels ==
              _scrollController.position.maxScrollExtent &&
          !_isLoading &&
          _hasMorePosts &&
          _postsError == null) {
        _fetchPosts(isLoadMore: true);
      }
    });
    // 启动时加载一次空搜索
    _fetchPosts();
    _loadCompletionSuggestions();
  }

  @override
  void dispose() {
    _postsCancelToken?.cancel();
    AppNetworkService.instance.removeListener(_networkSettingsChanged);
    _cancelCompletionQuery();
    unawaited(_disposeCompletionService());
    _searchController.removeListener(_refreshCompletionSuggestions);
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _pageFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _networkSettingsChanged() {
    if (mounted) unawaited(_fetchPosts(isRefresh: true));
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
    if (_isDownloading) return;
    final itemsToDownload = _selectedPosts();

    if (itemsToDownload.isEmpty) {
      _exitMultiSelectMode();
      return;
    }

    setState(() => _isDownloading = true);
    try {
      final unfinished = await showDialog<Set<int>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => DownloadProgressDialog(posts: itemsToDownload),
      );
      if (!mounted) return;
      if (unfinished != null) {
        final available = _posts.map((post) => post.id).toSet();
        setState(() {
          _selectedItems
            ..clear()
            ..addAll(unfinished.intersection(available));
          _isMultiSelectMode = _selectedItems.isNotEmpty;
        });
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
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

  String _queryTags() {
    final ratings = getSelectedRatings();
    return [
      ..._searchChips.map((chip) => chip.queryValue),
      ..._searchController.text.split(' ').where((tag) => tag.isNotEmpty),
      if (ratings.isNotEmpty) 'rating:${ratings.join(',')}',
    ].join(' ');
  }

  Future<void> _fetchPosts({
    bool isLoadMore = false,
    bool isRefresh = false,
  }) async {
    if (!mounted || (isLoadMore && (_isLoading || !_hasMorePosts))) return;

    _postsCancelToken?.cancel();
    final cancelToken = NetworkCancelToken();
    _postsCancelToken = cancelToken;

    final requestGeneration = isLoadMore
        ? _requestGeneration
        : ++_requestGeneration;
    final requestPage = isLoadMore ? _page + 1 : 1;
    // Pagination and refresh belong to the visible gallery, even while a new
    // query is being edited in the input field.
    if (!isLoadMore && !isRefresh) _activeQueryTags = _queryTags();
    final requestTags = _activeQueryTags;

    setState(() {
      _isLoading = true;
      _postsError = null;
      _failedLoadMore = false;
      if (!isLoadMore && !isRefresh) {
        _posts = [];
        _page = 1;
        _hasMorePosts = true;
        _selectedItems.clear();
        _isMultiSelectMode = false;
      }
    });

    if (!isLoadMore && !isRefresh && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    try {
      final uri = Uri.https('danbooru.donmai.us', '/posts.json', {
        'tags': requestTags,
        'limit': '100',
        'page': '$requestPage',
      });
      final response = widget.fetchPosts == null
          ? await AppNetworkService.instance.get(uri, cancelToken: cancelToken)
          : await widget.fetchPosts!(uri).timeout(const Duration(seconds: 25));
      if (!mounted || requestGeneration != _requestGeneration) return;
      if (response.statusCode != 200) {
        _recordPostsError(switch (response.statusCode) {
          401 || 403 => '服务器拒绝访问（HTTP ${response.statusCode}），请检查站点权限或访问限制。',
          429 => '请求过于频繁（HTTP 429），请稍后再试。',
          _ => '请求失败（HTTP ${response.statusCode}），请稍后重试。',
        }, isLoadMore: isLoadMore);
        return;
      }
      final List<dynamic> postsJson = json.decode(response.body);
      final newPosts = postsJson.map((json) => Post.fromJson(json)).toList();
      setState(() {
        if (isLoadMore) {
          final knownIds = _posts.map((post) => post.id).toSet();
          _posts.addAll(newPosts.where((post) => knownIds.add(post.id)));
        } else {
          _posts = newPosts;
        }
        _page = requestPage;
        _hasMorePosts = newPosts.isNotEmpty;
        final visibleIds = _posts.map((post) => post.id).toSet();
        _selectedItems.removeWhere((id) => !visibleIds.contains(id));
        if (_selectedItems.isEmpty) _isMultiSelectMode = false;
      });
    } on NetworkCancelledException {
      // A newer query, a proxy change or route disposal owns the next result.
    } on TimeoutException {
      if (mounted && requestGeneration == _requestGeneration) {
        _recordPostsError('连接超时，请检查网络后重试。', isLoadMore: isLoadMore);
      }
    } catch (error) {
      if (mounted && requestGeneration == _requestGeneration) {
        _recordPostsError(networkErrorMessage(error), isLoadMore: isLoadMore);
      }
    } finally {
      if (mounted && requestGeneration == _requestGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _recordPostsError(String message, {required bool isLoadMore}) {
    setState(() {
      _postsError = message;
      _failedLoadMore = isLoadMore;
    });
  }

  void _retryPosts() {
    _fetchPosts(isLoadMore: _failedLoadMore, isRefresh: !_failedLoadMore);
  }

  void _clearSearch() {
    _searchFocusNode.unfocus();
    _cancelCompletionQuery();
    setState(() {
      _setSearchInput('');
      _searchChips.clear();
      ratingOptions.updateAll((key, value) => false);
      _showSuggestions = false;
      _isQueryPending = false;
    });
    _fetchPosts();
  }

  void _dismissSearchOrSelection() {
    if (_showSuggestions || _searchFocusNode.hasFocus) {
      _searchFocusNode.unfocus();
      _pageFocusNode.requestFocus();
      _cancelCompletionQuery();
      setState(() {
        _showSuggestions = false;
        _isQueryPending = false;
      });
    } else if (_isMultiSelectMode) {
      _exitMultiSelectMode();
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
      title: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.grid_view_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: '网络设置',
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const NetworkSettingsPage()),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.collections_bookmark_outlined),
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
        tooltip: '退出多选',
        onPressed: _exitMultiSelectMode,
      ),
      title: Text(
        '${_selectedItems.length} 已选择',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: '下载选中作品',
          icon: const Icon(Icons.download),
          onPressed: _selectedItems.isEmpty || _isDownloading
              ? null
              : _batchDownload,
        ),
        IconButton(
          tooltip: '复制作品链接',
          icon: const Icon(Icons.link),
          onPressed: _selectedItems.isEmpty ? null : _batchCopyLinks,
        ),
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

  void _showTagValue(SearchChip chip) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('搜索标签'),
        content: SingleChildScrollView(
          child: SelectableText(
            chip.label == chip.queryValue
                ? chip.queryValue
                : '${chip.label}\n\n${chip.queryValue}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchPanel({required bool expanded}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GallerySearchPanel(
          controller: _searchController,
          focusNode: _searchFocusNode,
          expanded: expanded,
          hasQuery:
              _searchChips.isNotEmpty ||
              _searchController.text.isNotEmpty ||
              ratingOptions.values.any((selected) => selected),
          onClear: _clearSearch,
          onSearch: () {
            _searchFocusNode.unfocus();
            _submitSearchText(_searchController.text);
          },
          onSubmitted: (value) {
            _searchFocusNode.unfocus();
            _submitSearchText(value);
          },
          selectedTags: [
            for (var index = 0; index < _searchChips.length; index++)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (constraints.maxWidth - 32).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: InputChip(
                  label: Text(
                    _searchChips[index].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  tooltip: '查看完整标签',
                  deleteButtonTooltipMessage: '移除标签',
                  onPressed: () => _showTagValue(_searchChips[index]),
                  onDeleted: () => _removeSearchChip(index),
                ),
              ),
          ],
          filters: [
            for (final entry in ratingOptions.entries)
              FilterChip(
                label: Text(entry.key),
                selected: entry.value,
                onSelected: (selected) {
                  setState(() => ratingOptions[entry.key] = selected);
                  _fetchPosts();
                },
              ),
          ],
          suggestions: _showSuggestions ? _buildCompletionPanel() : null,
        );
      },
    );
  }

  Widget _buildGallery() {
    if (_posts.isEmpty) {
      if (_isLoading) {
        return const GalleryEmptyState(
          icon: Icons.photo_library_outlined,
          title: '正在加载作品',
          subtitle: '精彩内容即将呈现',
          action: SizedBox(width: 180, child: LinearProgressIndicator()),
        );
      }
      if (_postsError != null) {
        return GalleryEmptyState(
          icon: Icons.cloud_off_outlined,
          title: '作品加载失败',
          subtitle: _postsError!,
          action: FilledButton.icon(
            onPressed: _retryPosts,
            icon: const Icon(Icons.refresh),
            label: const Text('重新加载'),
          ),
        );
      }
      return GalleryEmptyState(
        icon: Icons.image_search_outlined,
        title: '暂无结果',
        subtitle: '试试其他标签或筛选条件',
        action: _activeQueryTags.isNotEmpty
            ? OutlinedButton(onPressed: _clearSearch, child: const Text('清空筛选'))
            : null,
      );
    }
    return GalleryGrid(
      controller: _scrollController,
      onRefresh: () => _fetchPosts(isRefresh: true),
      itemCount: _posts.length,
      itemBuilder: (context, index) {
        final post = _posts[index];
        final isSelected = _selectedItems.contains(post.id);
        return PostThumbnailTile(
          key: ValueKey('post_${post.id}'),
          previewUrl: post.previewFileUrl,
          highResUrl: post.fileUrl ?? post.largeFileUrl,
          heroTag: 'post_${post.id}',
          semanticLabel: '作品 ${post.id}',
          selected: _isMultiSelectMode ? isSelected : null,
          onTap: () {
            if (_isMultiSelectMode) {
              _toggleSelection(post.id);
            } else {
              _navigateToDetail(index);
            }
          },
          onLongPress: () {
            if (!_isMultiSelectMode) _enterMultiSelectMode(post.id);
          },
          overlay: isSelected
              ? Container(
                  color: Theme.of(
                    context,
                  ).colorScheme.scrim.withValues(alpha: 0.5),
                  child: const Icon(Icons.check_circle, color: Colors.white),
                )
              : null,
        );
      },
    );
  }

  Widget _buildGalleryPane() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 240;
        final showFeedback = _postsError != null && _posts.isNotEmpty;
        return Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * (showFeedback ? 0.6 : 0.5),
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    if (showFeedback)
                      GalleryRequestFeedback(
                        message: _postsError!,
                        onRetry: _retryPosts,
                        compact: compact,
                      ),
                    if (!showFeedback || !compact)
                      GallerySectionHeader(
                        compact: compact,
                        count: _posts.length,
                        isLoading: _isLoading,
                        onRefresh: () => _fetchPosts(isRefresh: true),
                        onSelect: _posts.isEmpty || _isMultiSelectMode
                            ? null
                            : () => setState(() => _isMultiSelectMode = true),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: _buildGallery()),
            if (_isLoading && _posts.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _searchFocusNode.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _searchFocusNode.requestFocus,
        const SingleActivator(LogicalKeyboardKey.escape):
            _dismissSearchOrSelection,
      },
      child: Focus(
        focusNode: _pageFocusNode,
        autofocus: true,
        child: PopScope(
          canPop: !_isMultiSelectMode,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _isMultiSelectMode) _exitMultiSelectMode();
          },
          child: Scaffold(
            appBar: _isMultiSelectMode
                ? _buildMultiSelectAppBar()
                : _buildDefaultAppBar(),
            body: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final expanded = constraints.maxWidth >= 1000;
                  final panel = _buildSearchPanel(expanded: expanded);
                  if (expanded) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 320,
                          child: Material(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerLow,
                            child: SingleChildScrollView(child: panel),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _buildGalleryPane()),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * 0.46,
                        ),
                        child: SingleChildScrollView(child: panel),
                      ),
                      const Divider(),
                      Expanded(child: _buildGalleryPane()),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
