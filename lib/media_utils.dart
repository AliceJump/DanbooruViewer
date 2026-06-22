// media_utils.dart
import 'dart:async';

import 'package:gal/gal.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// drag_utils.dart
import 'package:danbooru_viewer/DragHelper.dart';

/// 判断 URL 是否是视频
bool isVideoUrl(String url) {
  final lower = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return lower.endsWith('.mp4') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.m4v');
}

Future<File?> getCachedMediaFile(String? url) async {
  if (url == null || isVideoUrl(url)) return null;
  return (await DefaultCacheManager().getFileFromCache(url))?.file;
}

Future<File?> getCachedOrDownloadedMediaFile(String? url) async {
  if (url == null || isVideoUrl(url)) return null;
  return DefaultCacheManager().getSingleFile(url);
}

void warmPostImages({String? previewUrl, String? highResUrl}) {
  if (previewUrl != null) {
    DefaultCacheManager().downloadFile(previewUrl);
  }
  if (highResUrl != null && !isVideoUrl(highResUrl)) {
    DefaultCacheManager().downloadFile(highResUrl);
  }
}

Widget cachedHighResImageOrPreview({
  required String? highResUrl,
  required String? previewUrl,
  required BoxFit fit,
  double? width,
  double? height,
  ImageLoadingBuilder? loadingBuilder,
  ImageErrorWidgetBuilder? errorBuilder,
}) {
  return FutureBuilder<File?>(
    future: getCachedMediaFile(highResUrl),
    builder: (context, snapshot) {
      final cachedFile = snapshot.data;
      if (cachedFile != null) {
        return Image.file(
          cachedFile,
          width: width,
          height: height,
          fit: fit,
          errorBuilder: errorBuilder,
        );
      }
      if (previewUrl == null) return const Icon(Icons.image_not_supported);
      return CachedMediaImage(
        imageUrl: previewUrl,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: errorBuilder,
      );
    },
  );
}

class CachedMediaImage extends StatefulWidget {
  final String imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  const CachedMediaImage({
    super.key,
    required this.imageUrl,
    required this.fit,
    this.width,
    this.height,
    this.errorBuilder,
  });

  @override
  State<CachedMediaImage> createState() => _CachedMediaImageState();
}

class _CachedMediaImageState extends State<CachedMediaImage> {
  late Future<File?> _fileFuture;

  @override
  void initState() {
    super.initState();
    _fileFuture = getCachedOrDownloadedMediaFile(widget.imageUrl);
  }

  @override
  void didUpdateWidget(CachedMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _fileFuture = getCachedOrDownloadedMediaFile(widget.imageUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _fileFuture,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null) {
          return Image.file(
            file,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: widget.errorBuilder,
          );
        }

        if (snapshot.hasError) {
          return widget.errorBuilder?.call(context, snapshot.error!, null) ??
              const Icon(Icons.error);
        }

        return const SizedBox.expand();
      },
    );
  }
}

class PostThumbnailTile extends StatelessWidget {
  final String? previewUrl;
  final String? highResUrl;
  final String heroTag;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Widget? overlay;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double? errorIconSize;

  const PostThumbnailTile({
    super.key,
    required this.previewUrl,
    required this.highResUrl,
    required this.heroTag,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.overlay,
    this.onTap,
    this.onLongPress,
    this.errorIconSize,
  });

  @override
  Widget build(BuildContext context) {
    if (previewUrl == null) {
      return const GridTile(child: Icon(Icons.image_not_supported));
    }

    final image = Stack(
      fit: StackFit.expand,
      children: [
        Hero(
          tag: heroTag,
          child: cachedHighResImageOrPreview(
            highResUrl: highResUrl,
            previewUrl: previewUrl,
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (context, error, stackTrace) =>
                Icon(Icons.error, size: errorIconSize),
          ),
        ),
        if (overlay != null) overlay!,
      ],
    );

    final content = SizedBox(
      width: width,
      height: height,
      child: borderRadius == null
          ? image
          : ClipRRect(borderRadius: borderRadius!, child: image),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: content,
    );
  }
}

class TimedMediaHoldGesture extends StatefulWidget {
  final String media;
  final Widget child;

  const TimedMediaHoldGesture({
    super.key,
    required this.media,
    required this.child,
  });

  @override
  State<TimedMediaHoldGesture> createState() => _TimedMediaHoldGestureState();
}

class _TimedMediaHoldGestureState extends State<TimedMediaHoldGesture> {
  Timer? _dragTimer;
  bool _didStartDrag = false;

  @override
  void dispose() {
    _dragTimer?.cancel();
    super.dispose();
  }

  void _startHoldTimer() {
    _dragTimer?.cancel();
    _didStartDrag = false;
    _dragTimer = Timer(const Duration(seconds: 1), () {
      _didStartDrag = true;
      startDrag(context, widget.media);
    });
  }

  void _finishHold() {
    final shouldSave = _dragTimer?.isActive == true && !_didStartDrag;
    _dragTimer?.cancel();
    if (shouldSave) {
      saveMediaToGallery(context, widget.media);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: (_) => _startHoldTimer(),
      onLongPressEnd: (_) => _finishHold(),
      onLongPressCancel: () => _dragTimer?.cancel(),
      child: widget.child,
    );
  }
}

/// 获取缓存文件（支持重试）
Future<File> getCachedFile(String url, {int retries = 2}) async {
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

/// 触发原生拖拽
/// [context] 用于 SnackBar 提示错误
/// [mediaUrl] 图片或视频 URL
Future<void> startDrag(BuildContext context, String media) async {
  if (media.isEmpty) return;

  final type = isVideoUrl(media) ? "video" : "image";
  String filePath;

  try {
    if (media.startsWith('http://') || media.startsWith('https://')) {
      // URL → 获取缓存文件
      filePath = (await getCachedFile(media)).path;
    } else {
      // 本地文件路径
      filePath = media;
    }

    await DragHelper.startDrag(filePath, type: type);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('无法拖拽: $e')));
  }
}

Future<void> saveMediaToGallery(BuildContext context, String mediaUrl) async {
  try {
    final hasAccess = await Gal.hasAccess();
    if (!hasAccess) {
      final status = await Gal.requestAccess();
      if (!status) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('需要存储权限来保存文件')));
        return;
      }
    }

    // 判断是网络 URL 还是本地路径
    final file =
        (mediaUrl.startsWith('http://') || mediaUrl.startsWith('https://'))
        ? await DefaultCacheManager().getSingleFile(mediaUrl)
        : File(mediaUrl);

    final isVideo = mediaUrl.toLowerCase().endsWith('.mp4');

    if (isVideo) {
      await Gal.putVideo(file.path, album: 'danbooru_viewer');
    } else {
      await Gal.putImage(file.path, album: 'danbooru_viewer');
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${isVideo ? '视频' : '图片'}已保存到相册')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
  }
}
