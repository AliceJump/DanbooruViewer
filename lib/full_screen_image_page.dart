import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';
import 'media_utils.dart';

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

Timer? pressTimer;
DateTime? pressStartTime;

class _FullScreenImagePageState extends State<FullScreenImagePage> {
  late String _currentImageUrl;
  ImageProvider? _imageProvider;
  File? _cachedImageFile;
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
      _loadHighResMedia();
      _didLoadHighRes = true;
    }
  }

  bool _isVideoUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v');
  }

  Future<File> _getCachedFile(String url, {int retries = 2}) async {
    var attempt = 0;
    while (true) {
      try {
        return await DefaultCacheManager().getSingleFile(url);
      } catch (_) {
        if (attempt++ >= retries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
  }

  Future<void> _loadHighResMedia() async {
    final highResUrl = widget.highResUrl;
    if (highResUrl == null || highResUrl == widget.previewUrl) return;

    try {
      if (_isVideoUrl(highResUrl)) {
        final file = await _getCachedFile(highResUrl);
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        if (mounted) {
          setState(() {
            _videoController = controller;
            _isVideo = true;
          });
        }
      } else {
        final file = await _getCachedFile(highResUrl);
        if (mounted) {
          setState(() {
            _currentImageUrl = highResUrl;
            _cachedImageFile = file;
            _imageProvider = FileImage(file);
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      body: GestureDetector(
        onTapDown: (_) {
          pressStartTime = DateTime.now();
          pressTimer = Timer(const Duration(seconds: 1), () {
            pressTimer = null; // Timer 已触发，拖拽开始
            String? url;

            if (_isVideo && _videoController != null) {
              // 如果是视频，用 highResUrl
              url = widget.highResUrl ?? widget.previewUrl;
            } else {
              // 图片，优先用缓存文件路径
              url =
                  _cachedImageFile?.path ??
                      widget.highResUrl ??
                      widget.previewUrl;
            }
            startDrag(context,url);
          });
        },
        onTapUp: (_) {
          if (pressTimer != null && pressTimer!.isActive) {
            pressTimer?.cancel();
            pressTimer = null;

            // 计算按住时长
            final elapsed = DateTime.now()
                .difference(pressStartTime!)
                .inMilliseconds;

            if (elapsed >= 300) {
              // 按住至少0.3s → 下载
              String? url;

              if (_isVideo && _videoController != null) {
                // 如果是视频，用 highResUrl
                url = widget.highResUrl ?? widget.previewUrl;
              } else {
                // 图片，优先用缓存文件路径
                url =
                    _cachedImageFile?.path ??
                    widget.highResUrl ??
                    widget.previewUrl;
              }
              saveMediaToGallery(context, url);
            } else {
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
            }
          }
        },

        onTapCancel: () {
          pressTimer?.cancel();
          pressTimer = null;
        },
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
                    return const SizedBox.shrink();
                  },
                ),
        ),
      ),
    );
  }
}
