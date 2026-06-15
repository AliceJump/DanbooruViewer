import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/favorites_page.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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
    };
  }
}

class SearchCompletionSuggestion {
  final String value;
  final String insertValue;
  final String source;
  final int score;

  SearchCompletionSuggestion({
    required this.value,
    required this.insertValue,
    required this.source,
    required this.score,
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
    );
  }
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
  List<SearchCompletionSuggestion> _completionSuggestions = [];
  List<SearchCompletionSuggestion> _visibleSuggestions = [];
  final Map<String, String> _completionDisplayByInsertValue = {};
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
      final bytes = await rootBundle.load('assets/danbooru_completion.zip');
      final archive = ZipDecoder().decodeBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      final jsonFiles =
          archive.files
              .where((file) => file.isFile && file.name.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      final suggestionsByValue = <String, SearchCompletionSuggestion>{};

      for (final file in jsonFiles) {
        try {
          final content = utf8.decode(file.content as List<int>);
          final payload = json.decode(content);
          final candidateJson = payload is List<dynamic>
              ? payload
              : payload is Map<String, dynamic>
              ? payload['completion_candidates'] as List<dynamic>? ?? []
              : const <dynamic>[];
          final candidates = candidateJson
              .whereType<Map<String, dynamic>>()
              .map(SearchCompletionSuggestion.fromJson)
              .where(
                (item) =>
                    item.value.trim().isNotEmpty &&
                    item.insertValue.trim().isNotEmpty,
              );

          for (final candidate in candidates) {
            final key =
                '${candidate.value.toLowerCase()}\u0000${candidate.insertValue.toLowerCase()}';
            final existing = suggestionsByValue[key];
            if (existing == null || candidate.score > existing.score) {
              suggestionsByValue[key] = candidate;
            }
          }
        } catch (e) {
          debugPrint('Skipped completion asset ${file.name}: $e');
        }
      }

      final candidates = suggestionsByValue.values.toList()
        ..sort((a, b) => b.score.compareTo(a.score));

      if (!mounted) return;
      setState(() {
        _completionSuggestions = candidates;
        _completionDisplayByInsertValue
          ..clear()
          ..addAll(_buildCompletionDisplayByInsertValue(candidates));
        _isCompletionLoading = false;
        _completionLoadError = candidates.isEmpty
            ? '未读取到 danbooru_completion 补全数据'
            : null;
      });
      _refreshCompletionSuggestions();
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

  Map<String, String> _buildCompletionDisplayByInsertValue(
    List<SearchCompletionSuggestion> candidates,
  ) {
    final displays = <String, String>{};
    for (final candidate in candidates) {
      final key = candidate.insertValue.toLowerCase();
      final label = candidate.value.trim();
      if (key.isEmpty || label.isEmpty) continue;

      final existing = displays[key];
      if (existing == null ||
          (!_containsNonEnglish(existing) && _containsNonEnglish(label))) {
        displays[key] = label;
      }
    }
    return displays;
  }

  bool _containsNonEnglish(String value) {
    return value.runes.any((rune) => rune > 0x7f);
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

  void _refreshCompletionSuggestions() {
    if (!mounted || _isCompletionLoading) {
      if (_searchFocusNode.hasFocus) {
        setState(() {
          _showSuggestions = true;
        });
      }
      return;
    }

    final token = _currentSearchToken();
    final query = token.value.toLowerCase();
    final matches = query.isEmpty
        ? _completionSuggestions.take(10).toList()
        : _completionSuggestions
              .where(
                (item) =>
                    item.value.toLowerCase().contains(query) ||
                    item.insertValue.toLowerCase().contains(query),
              )
              .take(10)
              .toList();

    setState(() {
      _visibleSuggestions = matches;
      _showSuggestions = _searchFocusNode.hasFocus;
    });
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

  void _upsertSearchChip(SearchChip chip) {
    final normalizedQuery = chip.queryValue.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return;

    _searchChips.removeWhere(
      (item) => item.queryValue.trim().toLowerCase() == normalizedQuery,
    );
    _searchChips.add(chip);
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
    final itemsToDownload = _posts
        .where((post) => _selectedItems.contains(post.id))
        .toList();

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
    final links = _posts
        .where((post) => _selectedItems.contains(post.id))
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
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PostDetailPage(
          posts: _posts,
          initialIndex: index,
          completionDisplayByValue: _completionDisplayByInsertValue,
        ),
      ),
    );

    if (result is SearchChip) {
      _addSearchChip(result.label, result.queryValue);
    } else if (result != null && result is String) {
      _addSearchChip(result, result);
    }
  }

  AppBar _buildDefaultAppBar() {
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      title: Text(widget.title),
      actions: [
        IconButton(
          icon: const Icon(Icons.favorite),
          onPressed: () async {
            final result = await Navigator.push<String>(
              context,
              MaterialPageRoute(builder: (context) => const FavoritesPage()),
            );
            if (result != null && mounted) {
              _addSearchChip(result, result);
            }
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
          : ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _visibleSuggestions.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final suggestion = _visibleSuggestions[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    suggestion.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${suggestion.source} · ${suggestion.score}'),
                  onTap: () => _applyCompletionSuggestion(suggestion),
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
                onSubmitted: (_) {
                  _searchFocusNode.unfocus();
                  _fetchPosts();
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
                              if (post.previewFileUrl != null) {
                                return GestureDetector(
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
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Hero(
                                        tag: 'post_${post.id}',
                                        child: Image.network(
                                          post.previewFileUrl!,
                                          fit: BoxFit.cover,
                                          loadingBuilder: (context, child, loadingProgress) {
                                            if (loadingProgress == null) {
                                              return child;
                                            }
                                            return Center(
                                              child: CircularProgressIndicator(
                                                value:
                                                    loadingProgress
                                                            .expectedTotalBytes !=
                                                        null
                                                    ? loadingProgress
                                                              .cumulativeBytesLoaded /
                                                          loadingProgress
                                                              .expectedTotalBytes!
                                                    : null,
                                              ),
                                            );
                                          },
                                          errorBuilder:
                                              (context, error, stackTrace) {
                                                return const Icon(Icons.error);
                                              },
                                        ),
                                      ),
                                      if (isSelected)
                                        Container(
                                          color: Colors.black.withValues(
                                            alpha: 0.5,
                                          ),
                                          child: const Icon(
                                            Icons.check_circle,
                                            color: Colors.white,
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              } else {
                                return const GridTile(
                                  child: Icon(Icons.image_not_supported),
                                );
                              }
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
