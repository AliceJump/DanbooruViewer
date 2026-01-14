import 'dart:convert';

import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
      // Scroll to top when performing a new search
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
            _page--; // No more posts, revert page increment
          }
          return;
        }
        final newPosts =
            postsJson.map((json) => Post.fromJson(json)).toList();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
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
                      if (post.previewFileUrl != null) {
                        return GestureDetector(
                          onTap: () => _navigateToDetail(index),
                          child: Hero(
                            tag: 'post_${post.id}',
                            child: GridTile(
                              child: Image.network(
                                post.previewFileUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return const Icon(Icons.error);
                                },
                              ),
                            ),
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
