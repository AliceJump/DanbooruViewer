import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'favorites_manager.dart';
import 'full_screen_image_page.dart';
import 'DragHelper.dart';
import 'main.dart';

class PostDetailPage extends StatefulWidget {
  final List<Post> posts;
  final int initialIndex;
  final Map<String, String> completionDisplayByValue;

  const PostDetailPage({
    super.key,
    required this.posts,
    required this.initialIndex,
    required this.completionDisplayByValue,
  });

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, String> _imageUrls = {};
  final Map<int, VideoPlayerController> _videoControllers = {};
  bool _didChangeDependenciesRun = false;

  final _favoritesManager = FavoritesManager();
  bool _isFavorite = false;
  bool _didTriggerDragAction = false;
  double? _verticalDragStartDy;

  static const double _dragActionThreshold = 120.0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _checkFavoriteStatus();
    _recordCurrentPostHistory();
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
      _loadHighResImageForIndex(_currentIndex);
      _didChangeDependenciesRun = true;
    }
  }

  void _loadHighResImageForIndex(int index) {
    if (index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    final highResUrl = post.fileUrl ?? post.largeFileUrl;

    if (highResUrl != null &&
        _imageUrls[index] == null &&
        _videoControllers[index] == null) {
      // 先尝试作为图片加载
      precacheImage(NetworkImage(highResUrl), context)
          .then((_) {
            if (mounted) {
              setState(() {
                _imageUrls[index] = highResUrl;
              });
            }
          })
          .catchError((_) {
            // 图片加载失败，尝试作为视频加载
            if (mounted && _videoControllers[index] == null) {
              final videoController = VideoPlayerController.networkUrl(
                Uri.parse(highResUrl),
              );
              videoController
                  .initialize()
                  .then((_) {
                    if (mounted) {
                      setState(() {
                        _videoControllers[index] = videoController;
                      });
                    }
                  })
                  .catchError((_) {
                    // 视频加载也失败，不做任何处理，保持使用预览图
                    videoController.dispose();
                  });
            }
          });
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _loadHighResImageForIndex(index);
    _checkFavoriteStatus();
    _recordCurrentPostHistory();
  }

  Future<void> _recordCurrentPostHistory() async {
    await _favoritesManager.addBrowsingHistory(
      widget.posts[_currentIndex].toJson(),
    );
  }

  Future<void> _startDragShare(String imageUrl) async {
    try {
      // 下载图片到临时文件
      final tempDir = await getTemporaryDirectory();
      final fileName = imageUrl.split('/').last;
      final tempFile = '${tempDir.path}/$fileName';

      // 下载图片
      await Dio().download(imageUrl, tempFile);

      await DragHelper.startDrag(tempFile);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('拖拽分享失败: $e')));
    }
  }

  Future<void> _toggleFavorite() async {
    final currentPost = widget.posts[_currentIndex];
    final newState = await _favoritesManager.toggleFavorite(currentPost.id);
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
    final newState = await _favoritesManager.toggleFavoriteTag(tag);
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
            icon: const Icon(Icons.open_in_new),
            label: const Text('站内原链接'),
          ),
          if (sourceUrl != null)
            OutlinedButton.icon(
              onPressed: () => _launchUrl(sourceUrl),
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
          final videoController = _videoControllers[index];
          final definitiveHighResUrl = post.fileUrl ?? post.largeFileUrl;
          final heroTag = 'post_${post.id}';

          if (previewUrl == null) {
            return const Center(child: Icon(Icons.broken_image));
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
            onLongPress: () {
              if (definitiveHighResUrl != null) {
                _startDragShare(definitiveHighResUrl);
              }
            },
            child: Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [
                Hero(
                  tag: heroTag,
                  child: Image.network(
                    previewUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.error),
                  ),
                ),
                if (videoController != null)
                  Center(
                    child: AspectRatio(
                      aspectRatio: videoController.value.aspectRatio,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VideoPlayer(videoController),
                          Center(
                            child: Icon(
                              Icons.play_circle_outline,
                              size: 60,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (highResUrlForDetailPage != null && videoController == null)
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
                if (highResUrlForDetailPage == null &&
                    videoController == null &&
                    (post.fileUrl != null || post.largeFileUrl != null))
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
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
        ],
      ),
      body: isLandscape
          ? Row(
              children: [
                Expanded(flex: 3, child: _buildMediaPager(screenSize.height)),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: _buildInfoPanel(currentPostForTags)),
              ],
            )
          : Column(
              children: [
                _buildMediaPager(screenSize.height * 0.5),
                Expanded(child: _buildInfoPanel(currentPostForTags)),
              ],
            ),
    );
  }
}
