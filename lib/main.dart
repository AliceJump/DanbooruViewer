import 'dart:convert';

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
  final String? tag_string_general;
  final String? tag_string_artist;
  final String? tag_string_character;
  final String? tag_string_copyright;
  final String? tag_string_meta;
  final String? source;

  Post({
    required this.id,
    required this.rating,
    required this.tagString,
    this.fileUrl,
    this.largeFileUrl,
    this.previewFileUrl,
    this.tag_string_general,
    this.tag_string_artist,
    this.tag_string_character,
    this.tag_string_copyright,
    this.tag_string_meta,
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
      tag_string_general: json['tag_string_general'],
      tag_string_artist: json['tag_string_artist'],
      tag_string_character: json['tag_string_character'],
      tag_string_copyright: json['tag_string_copyright'],
      tag_string_meta: json['tag_string_meta'],
      source: json['source'],
    );
  }
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
  final ScrollController _scrollController = ScrollController();
  List<Post> _posts = [];
  bool _isLoading = false;
  int _page = 1;

  // Multi-select state
  bool _isMultiSelectMode = false;
  final Set<int> _selectedItems = {};

  Map<String, bool> ratingOptions = {
    "全年龄 (R-0)": true,
    "轻度提示 (R-12)": false,
    "青少年警告 (R-15)": false,
    "成人限制 (R-18)": false,
  };

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels ==
              _scrollController.position.maxScrollExtent &&
          !_isLoading) {
        _fetchPosts(isLoadMore: true);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要存储权限来保存图片')),
          );
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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$successCount 张图片已保存到相册')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败: $e')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可复制的链接')),
      );
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
      String tags = _searchController.text;
      List<String> ratings = getSelectedRatings();

      String ratingTags =
          ratings.isNotEmpty ? 'rating:${ratings.join(',')}' : '';
      String searchTags = tags.split(' ').where((s) => s.isNotEmpty).join('+');
      String finalTags = searchTags;
      if (ratingTags.isNotEmpty) {
        if (finalTags.isNotEmpty) {
          finalTags += '+$ratingTags';
        } else {
          finalTags = ratingTags;
        }
      }

      final response = await http.get(Uri.parse(
          'https://danbooru.donmai.us/posts.json?tags=$finalTags&limit=100&page=$_page'));

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
        print('Failed to load posts');
      }    } catch (e) {
      if (isLoadMore) _page--;
      print('Error fetching posts: $e');
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
        ),
      ),
    );

    if (result != null && result is String) {
      _searchController.text = result;
      _fetchPosts();
    }
  }

  AppBar _buildDefaultAppBar() {
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      title: Text(widget.title),
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
        IconButton(
          icon: const Icon(Icons.download),
          onPressed: _batchDownload,
        ),
        IconButton(
          icon: const Icon(Icons.link),
          onPressed: _batchCopyLinks,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isMultiSelectMode ? _buildMultiSelectAppBar() : _buildDefaultAppBar(),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => _fetchPosts(),
                ),
              ),
              onSubmitted: (_) => _fetchPosts(),
            ),
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
                      final isSelected = _selectedItems.contains(post.id);
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
                                  loadingBuilder:
                                      (context, child, loadingProgress) {
                                    if (loadingProgress == null) return child;
                                    return Center(
                                      child: CircularProgressIndicator(
                                        value: loadingProgress
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
                                  color: Colors.black.withOpacity(0.5),
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
    );
  }
}
