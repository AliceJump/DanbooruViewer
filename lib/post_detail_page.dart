import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'full_screen_image_page.dart';
import 'main.dart';

class PostDetailPage extends StatefulWidget {
  final List<Post> posts;
  final int initialIndex;

  const PostDetailPage({
    super.key,
    required this.posts,
    required this.initialIndex,
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

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
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
                return ActionChip(
                  label: Text(tag),
                  onPressed: () {
                    Navigator.pop(context, tag);
                  },
                  labelStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.all(2.0),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _launchUrl(String? urlString) async {
    if (urlString != null &&
        urlString.isNotEmpty &&
        await canLaunchUrl(Uri.parse(urlString))) {
      await launchUrl(
        Uri.parse(urlString),
        mode: LaunchMode.externalApplication,
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开链接: $urlString')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPostForTags = widget.posts[_currentIndex];

    return Scaffold(
      appBar: AppBar(title: Text('Post #${currentPostForTags.id}')),
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
                    onLongPress: () =>
                        _saveImage(definitiveHighResUrl ?? previewUrl),
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
                                      color: Colors.white.withValues(alpha: 0.7),
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
