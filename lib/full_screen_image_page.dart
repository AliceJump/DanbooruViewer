import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';

class FullScreenImagePage extends StatefulWidget {
  final String previewUrl;
  final String? highResUrl;
  final String heroTag;

  const FullScreenImagePage({
    super.key,
    required this.previewUrl,
    this.highResUrl,
    required this.heroTag,
  });

  @override
  State<FullScreenImagePage> createState() => _FullScreenImagePageState();
}

class _FullScreenImagePageState extends State<FullScreenImagePage> {
  late String _currentImageUrl;
  ImageProvider? _imageProvider;
  VideoPlayerController? _videoController;
  bool _didLoadHighRes = false;
  bool _isVideo = false;
  bool _videoIsPlaying = false;

  @override
  void initState() {
    super.initState();
    _currentImageUrl = widget.previewUrl;
    _imageProvider = NetworkImage(_currentImageUrl);
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoadHighRes) {
      _loadHighResImage();
      _didLoadHighRes = true;
    }
  }

  void _loadHighResImage() {
    if (widget.highResUrl != null && widget.highResUrl != widget.previewUrl) {
      // 先尝试作为图片加载
      precacheImage(NetworkImage(widget.highResUrl!), context)
          .then((_) {
            if (mounted && !_isVideo) {
              setState(() {
                _currentImageUrl = widget.highResUrl!;
                _imageProvider = NetworkImage(_currentImageUrl);
              });
            }
          })
          .catchError((_) {
            // 图片加载失败，尝试作为视频加载
            if (mounted && !_isVideo) {
              final videoController = VideoPlayerController.networkUrl(
                Uri.parse(widget.highResUrl!),
              );
              videoController
                  .initialize()
                  .then((_) {
                    if (mounted) {
                      setState(() {
                        _videoController = videoController;
                        _isVideo = true;
                      });
                    }
                  })
                  .catchError((_) {
                    // 视频加载也失败，保持使用预览图
                    videoController.dispose();
                  });
            }
          });
    }
  }

  Future<void> _saveImage() async {
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
      final path = '${tempDir.path}/image.jpg';
      await Dio().download(_currentImageUrl, path);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          if (_isVideo && _videoController != null) {
            setState(() {
              if (_videoIsPlaying) {
                _videoController!.pause();
              } else {
                _videoController!.play();
              }
              _videoIsPlaying = !_videoIsPlaying;
            });
          } else {
            Navigator.of(context).pop();
          }
        },
        onLongPress: () => _saveImage(),
        child: Center(
          child: _isVideo && _videoController != null
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: _videoController!.value.aspectRatio,
                      child: VideoPlayer(_videoController!),
                    ),
                    if (!_videoIsPlaying)
                      Icon(
                        Icons.play_circle_outline,
                        size: 80,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                  ],
                )
              : PhotoView(
                  imageProvider: _imageProvider,
                  heroAttributes: PhotoViewHeroAttributes(tag: widget.heroTag),
                  loadingBuilder: (context, event) => Center(
                    child: CircularProgressIndicator(
                      value: event == null || event.expectedTotalBytes == null
                          ? null
                          : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                    ),
                  ),
                  errorBuilder: (context, error, stackTrace) {
                    // 图片加载失败，显示预览图
                    return const SizedBox.shrink();
                  },
                ),
        ),
      ),
    );
  }
}
