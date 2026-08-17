import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'favorites_manager.dart';
import 'full_screen_image_page.dart';
import 'main.dart';
import 'media_utils.dart';
import 'ugoira_utils.dart';
import 'video_controls.dart';

class PostDetailPage extends StatefulWidget {
  final List<Post> posts;
  final int initialIndex;
  final Map<String, String> completionDisplayByValue;
  final Map<String, int> completionCategoryByValue;

  const PostDetailPage({
    super.key,
    required this.posts,
    required this.initialIndex,
    required this.completionDisplayByValue,
    this.completionCategoryByValue = const {},
  });

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

Future<Object?> openPostDetailPage({
  required BuildContext context,
  required List<Post> posts,
  required int initialIndex,
  required Map<String, String> completionDisplayByValue,
  Map<String, int> completionCategoryByValue = const {},
}) {
  if (initialIndex >= 0 && initialIndex < posts.length) {
    final post = posts[initialIndex];
    warmPostImages(
      previewUrl: post.previewFileUrl,
      highResUrl: post.fileUrl ?? post.largeFileUrl,
    );
  }

  return Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => PostDetailPage(
        posts: posts,
        initialIndex: initialIndex,
        completionDisplayByValue: completionDisplayByValue,
        completionCategoryByValue: completionCategoryByValue,
      ),
    ),
  );
}

class _PostDetailPageState extends State<PostDetailPage> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, String> _imageUrls = {};
  final Map<int, File> _imageFiles = {};
  final Map<int, String> _commentaryByPostId = {};
  final Map<int, VideoPlayerController> _videoControllers = {};
  bool _didChangeDependenciesRun = false;

  final _favoritesManager = FavoritesManager();
  bool _isFavorite = false;
  bool _didTriggerDragAction = false;
  bool _canShowLoadedImage = false;
  double? _verticalDragStartDy;

  static const double _dragActionThreshold = 120.0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _checkFavoriteStatus();
    _recordCurrentPostHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _canShowLoadedImage = true;
          });
        }
      });
    });
  }

  Future<void> _checkFavoriteStatus() async {
    final currentPost = widget.posts[_currentIndex];
    final isFav = await _favoritesManager.isFavorite(currentPost.id);
    if (mounted) {
      setState(() {
        _isFavorite = isFav;
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    // 清理所有视频控制器
    for (var controller in _videoControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didChangeDependenciesRun) {
      _loadMediaForIndex(_currentIndex, prioritizePreview: true);
      _didChangeDependenciesRun = true;
    }
  }

  Future<void> _loadMediaForIndex(
    int index, {
    bool prioritizePreview = false,
  }) async {
    if (index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    // 拉图时顺带拉取并缓存分享简介，分享时无需再发请求。
    _prefetchCommentary(post);
    final previewUrl = post.previewFileUrl;
    final highResUrl = post.fileUrl ?? post.largeFileUrl;

    if (prioritizePreview && previewUrl != null) {
      try {
        await precacheImage(NetworkImage(previewUrl), context);
      } catch (e) {
        debugPrint('Failed to precache preview for post ${post.id}: $e');
      }
      if (!mounted) return;
    }

    if (highResUrl != null &&
        _imageUrls[index] == null &&
        _videoControllers[index] == null &&
        _imageFiles[index] == null) {
      if (isUgoiraUrl(highResUrl)) {
        try {
          final gifFile = await getUgoiraGifFile(highResUrl);
          if (!mounted) return;
          setState(() {
            _imageFiles[index] = gifFile;
          });
        } catch (e) {
          debugPrint('Failed to process ugoira for post ${post.id}: $e');
        }
        return;
      }

      if (isVideoUrl(highResUrl)) {
        final videoController = VideoPlayerController.networkUrl(
          Uri.parse(highResUrl),
        );
        videoController
            .initialize()
            .timeout(const Duration(seconds: 12))
            .then((_) {
              if (!mounted) {
                videoController.dispose();
                return;
              }
              setState(() {
                _videoControllers[index] = videoController;
              });
            })
            .catchError((_) {
              videoController.dispose();
            });
        return;
      }

      try {
        await precacheImage(NetworkImage(highResUrl), context);
        if (!mounted) return;
        setState(() {
          _imageUrls[index] = highResUrl;
        });
      } catch (e) {
        debugPrint('Failed to precache image for post ${post.id}: $e');
      }
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _loadMediaForIndex(index, prioritizePreview: true);
    _checkFavoriteStatus();
    _recordCurrentPostHistory();
  }

  Future<void> _recordCurrentPostHistory() async {
    await _favoritesManager.addBrowsingHistory(
      widget.posts[_currentIndex].toJson(),
    );
  }

  Future<void> _toggleFavorite() async {
    final currentPost = widget.posts[_currentIndex];
    final newState = await _favoritesManager.toggleFavorite(
      currentPost.toJson(),
    );
    if (mounted) {
      setState(() {
        _isFavorite = newState;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newState ? '已添加到收藏' : '已取消收藏'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _toggleFavoriteTag(String tag) async {
    final category = widget.completionCategoryByValue[tag.toLowerCase()];
    final newState = await _favoritesManager.toggleFavoriteTag(
      tag,
      category: category,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newState ? '已收藏标签: $tag' : '已取消收藏标签: $tag'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _copyTag(String tag) {
    Clipboard.setData(ClipboardData(text: tag));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制标签: $tag'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _copyLink(String url, String label) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制$label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _sharePost(Post post) async {
    // 简介已缓存时直接分享，无需等待网络请求。
    final hasCachedIntro = _commentaryByPostId[post.id] != null ||
        await _favoritesManager.getCachedCommentary(post.id) != null;
    if (!mounted) return;
    if (!hasCachedIntro) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正在获取分享简介...'),
          duration: Duration(milliseconds: 800),
        ),
      );
    }

    final postUrl = _postUrl(post);
    final intro = await _postIntro(post);
    final text = intro == null || intro.isEmpty
        ? postUrl
        : '$postUrl\n\n$intro';

    try {
      await Share.share(text, subject: 'Danbooru Post #${post.id}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('分享失败: $e')));
    }
  }

  Future<String?> _postIntro(Post post) async {
    final cached = _commentaryByPostId[post.id];
    if (cached != null) return cached.isEmpty ? null : cached;

    // 读取持久化缓存（上次拉图时已保存的简介）。
    final persisted = await _favoritesManager.getCachedCommentary(post.id);
    if (persisted != null) {
      _commentaryByPostId[post.id] = persisted;
      return persisted.isEmpty ? null : persisted;
    }

    final commentary = await _fetchArtistCommentary(post.id);
    if (commentary != null) {
      await _favoritesManager.setCachedCommentary(post.id, commentary);
    }
    final intro = commentary ?? _fallbackPostIntro(post);
    if (intro != null && intro.isNotEmpty) {
      _commentaryByPostId[post.id] = intro;
    }
    return intro;
  }

  /// 拉图时后台预取简介：优先用持久化缓存，否则请求一次并保存，
  /// 这样点分享时 `_postIntro` 直接从缓存读取，无需再发网络请求。
  Future<void> _prefetchCommentary(Post post) async {
    if (_commentaryByPostId.containsKey(post.id)) return;

    final persisted = await _favoritesManager.getCachedCommentary(post.id);
    if (persisted != null) {
      _commentaryByPostId[post.id] = persisted;
      return;
    }

    final commentary = await _fetchArtistCommentary(post.id);
    if (commentary != null) {
      await _favoritesManager.setCachedCommentary(post.id, commentary);
      if (!_commentaryByPostId.containsKey(post.id)) {
        _commentaryByPostId[post.id] = commentary;
      }
    }
  }

  Future<String?> _fetchArtistCommentary(int postId) async {
    try {
      final uri = Uri.https('danbooru.donmai.us', '/artist_commentaries.json', {
        'search[post_id]': '$postId',
        'limit': '1',
      });
      final response = await http.get(uri);
      if (response.statusCode != 200) return null;

      final payload = json.decode(response.body);
      if (payload is! List || payload.isEmpty || payload.first is! Map) {
        return null;
      }

      final commentary = Map<String, dynamic>.from(payload.first as Map);
      final title = _firstNonEmpty([
        commentary['translated_title'],
        commentary['original_title'],
      ]);
      final description = _firstNonEmpty([
        commentary['translated_description'],
        commentary['original_description'],
      ]);

      return [title, description]
          .whereType<String>()
          .map(_normalizeShareText)
          .where((value) => value.isNotEmpty)
          .join('\n');
    } catch (e) {
      debugPrint('Failed to load artist commentary for post $postId: $e');
      return null;
    }
  }

  String? _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  String _normalizeShareText(String text) {
    return text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  String? _fallbackPostIntro(Post post) {
    final lines = [
      if (post.tagStringArtist?.trim().isNotEmpty == true)
        '作者: ${post.tagStringArtist}',
      if (post.tagStringCopyright?.trim().isNotEmpty == true)
        '版权: ${post.tagStringCopyright}',
      if (post.tagStringCharacter?.trim().isNotEmpty == true)
        '角色: ${post.tagStringCharacter}',
      if (post.rating.trim().isNotEmpty) 'Rating: ${post.rating}',
    ];
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  void _handleDragAction(double currentDy) {
    if (_didTriggerDragAction) return;
    final startDy = _verticalDragStartDy;
    if (startDy == null) return;

    final dragDistance = currentDy - startDy;
    if (dragDistance < -_dragActionThreshold) {
      _didTriggerDragAction = true;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('准备复制链接 ⬆')));
    }
  }

  Widget _buildTagSection(String title, String? tags, BuildContext context) {
    if (tags == null || tags.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final tagList = tags.trim().split(' ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
          const SizedBox(width: 16.0),
          Expanded(
            child: Wrap(
              spacing: 6.0,
              runSpacing: 4.0,
              children: tagList.map((tag) {
                final displayLabel = _displayLabelForTag(tag);
                return GestureDetector(
                  onLongPress: () {
                    _showTagMenu(context, tag);
                  },
                  child: InputChip(
                    label: Text(displayLabel),
                    onPressed: () {
                      Navigator.pop(
                        context,
                        SearchChip(label: displayLabel, queryValue: tag),
                      );
                    },
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  String _displayLabelForTag(String tag) {
    return widget.completionDisplayByValue[tag.toLowerCase()] ?? tag;
  }

  void _showTagMenu(BuildContext context, String tag) {
    showModalBottomSheet(
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
                Navigator.pop(context);
                Navigator.pop(context, tag);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制标签'),
              onTap: () {
                Navigator.pop(context);
                _copyTag(tag);
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite_border),
              title: const Text('收藏标签'),
              onTap: () {
                Navigator.pop(context);
                _toggleFavoriteTag(tag);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchUrl(String? urlString) async {
    final normalizedUrl = _normalizeUrl(urlString);
    if (normalizedUrl == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开链接: $urlString')));
      return;
    }

    try {
      final launched = await launchUrl(
        normalizedUrl,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return;

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开链接: $urlString')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开链接失败: $e')));
    }
  }

  Uri? _normalizeUrl(String? urlString) {
    final value = urlString?.trim();
    if (value == null || value.isEmpty) return null;

    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.hasScheme) return uri;

    return Uri.tryParse('https://$value');
  }

  String _postUrl(Post post) {
    return 'https://danbooru.donmai.us/posts/${post.id}';
  }

  String? _sourceUrl(Post post) {
    final source = post.source?.trim();
    if (source == null || source.isEmpty) return null;
    return _normalizePixivSource(source);
  }

  String _normalizePixivSource(String source) {
    final pixivIdPatterns = [
      RegExp(r'pixiv[./].*?[?&]illust_id=(\d+)', caseSensitive: false),
      RegExp(r'pixiv[./].*?/artworks/(\d+)', caseSensitive: false),
      RegExp(r'pixiv[./].*?/i/(\d+)', caseSensitive: false),
      RegExp(r'pixiv[./].*?/img-original/.*/(\d+)_p\d+', caseSensitive: false),
      RegExp(r'pximg\.net/.*/(\d+)_p\d+', caseSensitive: false),
    ];

    for (final pattern in pixivIdPatterns) {
      final match = pattern.firstMatch(source);
      if (match != null) {
        return 'https://www.pixiv.net/artworks/${match.group(1)}';
      }
    }
    return source;
  }

  Widget _buildLinkButtons(Post post) {
    final sourceUrl = _sourceUrl(post);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => _launchUrl(_postUrl(post)),
            onLongPress: () => _copyLink(_postUrl(post), '站内原链接'),
            icon: const Icon(Icons.open_in_new),
            label: const Text('站内原链接'),
          ),
          if (sourceUrl != null)
            OutlinedButton.icon(
              onPressed: () => _launchUrl(sourceUrl),
              onLongPress: () => _copyLink(sourceUrl, '源链接'),
              icon: const Icon(Icons.link),
              label: Text(
                _isPixivSource(sourceUrl) ? 'Pixiv 源链接' : 'Source 源链接',
              ),
            ),
        ],
      ),
    );
  }

  bool _isPixivSource(String source) {
    return source.toLowerCase().contains('pixiv.net');
  }

  double _portraitMediaHeight(Post post, Size screenSize) {
    final imageWidth = post.imageWidth;
    final imageHeight = post.imageHeight;
    if (imageWidth == null || imageHeight == null || imageWidth <= 0) {
      return screenSize.height * 0.5;
    }

    final naturalHeight = screenSize.width * imageHeight / imageWidth;
    return naturalHeight.clamp(
      screenSize.height * 0.32,
      screenSize.height * 0.72,
    );
  }

  Widget _buildMediaPager(double height) {
    return SizedBox(
      height: height,
      child: PageView.builder(
        controller: _pageController,
        itemCount: widget.posts.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final post = widget.posts[index];
          final previewUrl = post.previewFileUrl;
          final highResUrlForDetailPage = _imageUrls[index];
          final localImageFile = _imageFiles[index];
          final videoController = _videoControllers[index];
          final definitiveHighResUrl = post.fileUrl ?? post.largeFileUrl;
          final isVideo =
              definitiveHighResUrl != null && isVideoUrl(definitiveHighResUrl);
          final heroTag = 'post_${post.id}';

          if (previewUrl == null) {
            return const Center(child: Icon(Icons.broken_image));
          }

          Widget mediaContent = Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              Hero(
                tag: heroTag,
                child: cachedHighResImageOrPreview(
                  highResUrl: definitiveHighResUrl,
                  previewUrl: previewUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.error),
                ),
              ),
              if (videoController != null)
                Center(
                  child: DanbooruVideoPlayer(
                    controller: videoController,
                    compact: true,
                    onOpenFullScreen: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FullScreenImagePage(
                            previewUrl: previewUrl,
                            highResUrl: definitiveHighResUrl,
                            heroTag: heroTag,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              if (isVideo && videoController == null)
                Center(
                  child: Icon(
                    Icons.play_circle_outline,
                    size: 60,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              if (localImageFile != null)
                Center(
                  child: Image.file(
                    localImageFile,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              if (_canShowLoadedImage &&
                  highResUrlForDetailPage != null &&
                  videoController == null)
                AnimatedOpacity(
                  opacity: highResUrlForDetailPage != previewUrl ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Image.network(
                    highResUrlForDetailPage,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return const SizedBox.shrink();
                    },
                  ),
                ),
            ],
          );

          if (definitiveHighResUrl != null) {
            mediaContent = TimedMediaHoldGesture(
              media: localImageFile?.path ?? definitiveHighResUrl,
              child: mediaContent,
            );
          }

          return GestureDetector(
            onVerticalDragStart: (_) {
              _didTriggerDragAction = false;
              _verticalDragStartDy = null;
            },
            onVerticalDragUpdate: (details) {
              _verticalDragStartDy ??= details.localPosition.dy;
              _handleDragAction(details.localPosition.dy);
            },
            onVerticalDragEnd: (_) {
              _didTriggerDragAction = false;
              _verticalDragStartDy = null;
            },
            onVerticalDragCancel: () {
              _didTriggerDragAction = false;
              _verticalDragStartDy = null;
            },
            onTap: () {
              if (_didTriggerDragAction) return;

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => FullScreenImagePage(
                    previewUrl: previewUrl,
                    highResUrl: definitiveHighResUrl,
                    heroTag: heroTag,
                  ),
                ),
              );
            },
            child: mediaContent,
          );
        },
      ),
    );
  }

  Widget _buildInfoPanel(Post post) {
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      children: [
        _buildLinkButtons(post),
        _buildTagSection('作者', post.tagStringArtist, context),
        _buildTagSection('版权', post.tagStringCopyright, context),
        _buildTagSection('角色', post.tagStringCharacter, context),
        _buildTagSection('普通', post.tagStringGeneral, context),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentPostForTags = widget.posts[_currentIndex];
    final orientation = MediaQuery.orientationOf(context);
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = orientation == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        title: Text('Post #${currentPostForTags.id}'),
        actions: [
          IconButton(
            icon: Icon(
              _isFavorite ? Icons.favorite : Icons.favorite_border,
              color: _isFavorite ? Colors.red : null,
            ),
            onPressed: _toggleFavorite,
            tooltip: _isFavorite ? '取消收藏' : '收藏',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => _sharePost(currentPostForTags),
            tooltip: '分享',
          ),
        ],
      ),
      body: Flex(
        direction: isLandscape ? Axis.horizontal : Axis.vertical,
        children: [
          Expanded(
            flex: isLandscape ? 3 : 1,
            child: _buildMediaPager(
              isLandscape
                  ? screenSize.height
                  : _portraitMediaHeight(currentPostForTags, screenSize),
            ),
          ),
          if (isLandscape)
            const VerticalDivider(width: 1)
          else
            const Divider(height: 1),
          Expanded(
            flex: isLandscape ? 2 : 1,
            child: _buildInfoPanel(currentPostForTags),
          ),
        ],
      ),
    );
  }
}
