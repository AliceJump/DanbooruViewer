import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'favorites_manager.dart';
import 'full_screen_image_page.dart';
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
  Offset _dragStartOffset = Offset.zero;

  static const platform = MethodChannel(
    'com.example.danbooru_viewer/drag_drop',
  );

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _checkFavoriteStatus();
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
  }

  Future<void> _saveImage(String? imageUrl) async {
    if (imageUrl == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有可保存的图片')));
      return;
    }

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
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/${imageUrl.split('/').last}';
      await Dio().download(imageUrl, path);
      await Gal.putImage(path, album: 'danbooru_viewer');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('图片已保存到相册')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    }
  }

  Future<void> _startDragShare(String imageUrl) async {
    try {
      // 下载图片到临时文件
      final tempDir = await getTemporaryDirectory();
      final fileName = imageUrl.split('/').last;
      final tempFile = '${tempDir.path}/$fileName';

      // 下载图片
      await Dio().download(imageUrl, tempFile);

      // 调用 Android 原生方法启动拖拽
      final result = await platform.invokeMethod('startDragDrop', {
        'imagePath': tempFile,
        'mimeType': 'image/*',
      });

      debugPrint('Drag result: $result');
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

  void _handleDragAction(Offset dragOffset) {
    // 根据拖拽方向判断操作
    // 向左拖拽 -> 下载
    // 向右拖拽 -> 分享
    // 向上拖拽 -> 复制链接
    final dx = dragOffset.dx - _dragStartOffset.dx;
    final dy = dragOffset.dy - _dragStartOffset.dy;
    final distance = dragOffset.distance;

    if (distance > 100) {
      // 判断主要方向
      if (dx.abs() > dy.abs()) {
        // 水平拖拽
        if (dx < -50) {
          // 向左拖拽 -> 下载
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('准备下载 ⬅️')));
        } else if (dx > 50) {
          // 向右拖拽 -> 分享
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('准备分享 ➡️')));
        }
      } else {
        // 竖直拖拽
        if (dy < -50) {
          // 向上拖拽 -> 复制链接
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('准备复制链接 ⬆️')));
        }
      }
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

  @override
  Widget build(BuildContext context) {
    final currentPostForTags = widget.posts[_currentIndex];

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
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.posts.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) {
                  final post = widget.posts[index];
                  final previewUrl = post.previewFileUrl;
                  final highResUrlForDetailPage = _imageUrls[index];
                  final videoController = _videoControllers[index];
                  final definitiveHighResUrl =
                      post.fileUrl ?? post.largeFileUrl;
                  final heroTag = 'post_${post.id}';

                  if (previewUrl == null) {
                    return const Center(child: Icon(Icons.broken_image));
                  }

                  return GestureDetector(
                    onPanStart: (details) {
                      _dragStartOffset = details.localPosition;
                    },
                    onPanUpdate: (details) {
                      _handleDragAction(details.localPosition);
                    },
                    onPanEnd: (details) {
                      // reset start offset
                      _dragStartOffset = Offset.zero;
                    },
                    onTap: () {
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
                      // 长按触发拖拽分享
                      if (definitiveHighResUrl != null || previewUrl != null) {
                        _startDragShare(definitiveHighResUrl ?? previewUrl);
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
                        // 显示视频
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
                                      color: Colors.white.withValues(
                                        alpha: 0.7,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        // 显示高分辨率图片
                        if (highResUrlForDetailPage != null &&
                            videoController == null)
                          AnimatedOpacity(
                            opacity: highResUrlForDetailPage != previewUrl
                                ? 1.0
                                : 0.0,
                            duration: const Duration(milliseconds: 300),
                            child: Image.network(
                              highResUrlForDetailPage,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) {
                                // 高分辨率图片加载失败，显示预览图
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                        // 显示加载中指示器
                        if (highResUrlForDetailPage == null &&
                            videoController == null &&
                            (post.fileUrl != null || post.largeFileUrl != null))
                          const Center(child: CircularProgressIndicator()),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              const SizedBox(height: 16),
              _buildTagSection(
                '作者',
                currentPostForTags.tagStringArtist,
                context,
              ),
              _buildTagSection(
                '版权',
                currentPostForTags.tagStringCopyright,
                context,
              ),
              _buildTagSection(
                '角色',
                currentPostForTags.tagStringCharacter,
                context,
              ),
              _buildTagSection(
                '普通',
                currentPostForTags.tagStringGeneral,
                context,
              ),
            ]),
          ),
        ],
      ),
      floatingActionButton:
          (currentPostForTags.source != null &&
              currentPostForTags.source!.isNotEmpty)
          ? FloatingActionButton(
              onPressed: () => _launchUrl(currentPostForTags.source),
              child: const Icon(Icons.link),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }
}
