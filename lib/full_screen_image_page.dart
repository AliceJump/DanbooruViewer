import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
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

class _FullScreenImagePageState extends State<FullScreenImagePage> {
  late String _currentImageUrl;
  ImageProvider? _imageProvider;
  File? _cachedImageFile;
  VideoPlayerController? _videoController;
  bool _didLoadHighRes = false;
  bool _isVideo = false;
  bool _videoIsPlaying = false;
  bool _videoLoading = false;
  String? _videoLoadError;

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
        setState(() {
          _videoLoading = true;
          _videoLoadError = null;
        });

        final controller = VideoPlayerController.networkUrl(
          Uri.parse(highResUrl),
        );
        await controller.initialize().timeout(const Duration(seconds: 12));
        if (!mounted) {
          controller.dispose();
          return;
        }
        if (mounted) {
          setState(() {
            _videoController = controller;
            _isVideo = true;
            _videoLoading = false;
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
        setState(() {
          if (_isVideoUrl(highResUrl)) {
            _videoLoading = false;
            _videoLoadError = '视频加载失败';
          }
        });
      }
    }
  }

  String _activeMediaPathOrUrl() {
    if (_isVideo && _videoController != null) {
      return widget.highResUrl ?? widget.previewUrl;
    }

    return _cachedImageFile?.path ?? widget.highResUrl ?? widget.previewUrl;
  }

  void _handleTap() {
    if (_isVideo && _videoController != null) {
      setState(() {
        if (_videoIsPlaying) {
          _videoController!.pause();
        } else {
          _videoController!.play();
        }
        _videoIsPlaying = !_videoIsPlaying;
      });
      return;
    }

    Navigator.of(context).pop();
  }

  Widget _buildVideoPlaceholder() {
    if (_videoLoadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(
              _videoLoadError!,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _loadHighResMedia,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        const Center(child: CircularProgressIndicator()),
        if (widget.previewUrl.isNotEmpty)
          Image.network(
            widget.previewUrl,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
      ],
    );
  }

  Widget _buildMediaContent() {
    if (_isVideo && _videoController != null) {
      return Stack(
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
      );
    }

    if (_videoLoading || _videoLoadError != null) {
      return _buildVideoPlaceholder();
    }

    return PhotoView(
      imageProvider: _imageProvider,
      heroAttributes: PhotoViewHeroAttributes(tag: widget.heroTag),
      loadingBuilder: (context, event) => Center(
        child: CircularProgressIndicator(
          value: event == null || event.expectedTotalBytes == null
              ? null
              : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
        ),
      ),
      errorBuilder: (context, error, stackTrace) {
        return const SizedBox.shrink();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: TimedMediaHoldGesture(
          media: _activeMediaPathOrUrl(),
          child: Center(child: _buildMediaContent()),
        ),
      ),
    );
  }
}
