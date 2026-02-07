import 'dart:async';
import 'dart:io';

import 'package:danbooru_viewer/DragHelper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'full_screen_image_page.dart';
import 'main.dart';
import 'media_utils.dart';

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
  final Map<int, File> _imageFiles = {};
  final Map<int, VideoPlayerController> _videoControllers = {};
  bool _didChangeDependenciesRun = false;

  Timer? _pressTimer;
  final Stopwatch _pressStopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    _pressStopwatch.stop();
    for (var controller in _videoControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didChangeDependenciesRun) {
      _loadHighResForIndex(_currentIndex);
      _didChangeDependenciesRun = true;
    }
  }

  bool _isVideoUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v');
  }


  Future<void> _loadHighResForIndex(int index) async {
    if (index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    final highResUrl = post.fileUrl ?? post.largeFileUrl;
    if (highResUrl == null) return;
    if (_imageFiles[index] != null || _videoControllers[index] != null) return;

    try {
      if (_isVideoUrl(highResUrl)) {
        final file = await getCachedFile(highResUrl);
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        if (mounted) {
          setState(() {
            _videoControllers[index] = controller;
          });
        }
      } else {
        final file = await getCachedFile(highResUrl);
        if (mounted) {
          setState(() {
            _imageFiles[index] = file;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _loadHighResForIndex(index);
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
    if (urlString == null || urlString.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('链接无效')));
      return;
    }

    final Uri url = Uri.parse(urlString);

    try {
      await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法打开链接: $e')));
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
                  final highResFile = _imageFiles[index];
                  final videoController = _videoControllers[index];
                  final definitiveHighResUrl =
                      post.fileUrl ?? post.largeFileUrl;
                  final heroTag = 'post_${post.id}';

                  if (previewUrl == null) {
                    return const Center(child: Icon(Icons.broken_image));
                  }
                  Timer? pressTimer;
                  DateTime? pressStartTime;
                  return GestureDetector(
                    onTapDown: (_) {
                      pressStartTime = DateTime.now();
                      pressTimer = Timer(const Duration(seconds: 1), () {
                        pressTimer = null; // Timer 已触发，拖拽开始
                        startDrag(context,post.fileUrl as String);
                      });
                    },
                    onTapUp: (_) {
                      if (pressTimer != null && pressTimer!.isActive) {
                        pressTimer?.cancel();
                        pressTimer = null;

                        // 计算按住时长
                        final elapsed =
                            DateTime.now().difference(pressStartTime!).inMilliseconds;

                        if (elapsed >= 300) {
                          // 按住至少0.3s → 下载
                          saveMediaToGallery(context,definitiveHighResUrl!);
                        }else{
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
                        }

                      }
                    },

                    onTapCancel: () {
                      pressTimer?.cancel();
                      pressTimer = null;
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
                                      color: Colors.white.withOpacity(0.7),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (highResFile != null && videoController == null)
                          AnimatedOpacity(
                            opacity: 1.0,
                            duration: const Duration(milliseconds: 300),
                            child: Image.file(
                              highResFile,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              errorBuilder: (context, error, stackTrace) {
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                        if (highResFile == null &&
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
      floatingActionButton: (currentPostForTags.source != null &&
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