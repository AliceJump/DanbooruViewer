import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'DragHelper.dart';
import 'media_save_service.dart';
import 'media_types.dart';
import 'network/app_cache_manager.dart';
import 'network/app_network_service.dart';
import 'ugoira_utils.dart';

export 'media_types.dart';

String formatMediaLoadError(Object error) {
  if (error is NetworkException) return networkErrorMessage(error);
  if (error is FormatException) return error.message;
  if (error is TimeoutException) return '媒体加载超时，请重试或检查代理设置。';
  if (error is PlatformException) return '系统无法解码此媒体，可尝试外部播放或保存原文件。';
  return '媒体加载失败，请检查连接或代理设置后重试。';
}

bool get supportsNativeMediaDrag =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get supportsInlineVideo =>
    kIsWeb ||
    const [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ].contains(defaultTargetPlatform);

Future<File?> getCachedMediaFile(String? url) async {
  if (url == null || isVideoUrl(url)) return null;
  if (isUgoiraUrl(url)) {
    return getCachedUgoiraGifFile(url);
  }
  return (await AppCacheManager.instance.getFileFromCache(url))?.file;
}

Future<File?> getCachedOrDownloadedMediaFile(String? url) async {
  if (url == null || isVideoUrl(url)) return null;
  if (isUgoiraUrl(url)) {
    return getUgoiraGifFile(url);
  }
  return AppCacheManager.instance.getSingleFile(url);
}

final Set<String> _warmingImages = {};

void warmPostImages({String? previewUrl, String? highResUrl}) {
  final url = previewUrl ?? highResUrl;
  if (url == null ||
      isVideoUrl(url) ||
      isUgoiraUrl(url) ||
      _warmingImages.length >= 4 ||
      !_warmingImages.add(url)) {
    return;
  }
  unawaited(() async {
    try {
      await AppCacheManager.instance.getSingleFile(url);
    } on Object {
      // Prefetch is optional; the visible image owns its retry/error feedback.
    } finally {
      _warmingImages.remove(url);
    }
  }());
}

Future<ImageProvider> cachedMediaImageProvider(String url) async {
  final file = await getCachedOrDownloadedMediaFile(url);
  if (file == null) throw const FormatException('媒体不是可显示的图片。');
  return kIsWeb ? MemoryImage(await file.readAsBytes()) : FileImage(file);
}

int _videoCacheSequence = 0;

Future<VideoPlayerController> cachedVideoController(
  String url, {
  required NetworkCancelToken cancelToken,
}) async {
  cancelToken.throwIfCancelled();
  if (kIsWeb) return VideoPlayerController.networkUrl(Uri.parse(url));
  return VideoPlayerController.file(
    await cacheVideoFile(url, cancelToken: cancelToken),
  );
}

/// Stream a video through the configured proxy, publishing only complete files.
/// The per-session token cancels navigation downloads without cancelling images.
Future<File> cacheVideoFile(
  String url, {
  required NetworkCancelToken cancelToken,
  CacheManager? cacheManager,
  AppNetworkService? networkService,
}) async {
  final cache = cacheManager ?? AppCacheManager.instance;
  final existing = await cache.getFileFromCache(url);
  cancelToken.throwIfCancelled();
  if (existing != null &&
      await existing.file.exists() &&
      await existing.file.length() > 0) {
    return existing.file;
  }
  final extension = Uri.parse(url).path.split('.').last.toLowerCase();
  final fileName =
      'video_${DateTime.now().microsecondsSinceEpoch}_${_videoCacheSequence++}.$extension';
  final destination = await cache.config.fileSystem.createFile(fileName);
  final partial = await cache.config.fileSystem.createFile('$fileName.part');
  RandomAccessFile? output;
  bool published = false;
  try {
    cancelToken.throwIfCancelled();
    output = await partial.open(mode: FileMode.write);
    final response = await (networkService ?? AppNetworkService.instance)
        .stream(Uri.parse(url), cancelToken: cancelToken);
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw NetworkException(
        NetworkErrorKind.http,
        httpStatusMessage(response.statusCode),
        statusCode: response.statusCode,
      );
    }
    var received = 0;
    await for (final chunk in response.stream) {
      cancelToken.throwIfCancelled();
      await output.writeFrom(chunk);
      received += chunk.length;
    }
    await output.flush();
    await output.close();
    output = null;
    cancelToken.throwIfCancelled();
    final encoding = response.headers['content-encoding'];
    final expected = encoding == null || encoding == 'identity'
        ? response.contentLength
        : null;
    if (received == 0 || (expected != null && expected != received)) {
      throw const NetworkException(
        NetworkErrorKind.invalidResponse,
        '视频没有下载完整，请重试。',
      );
    }
    await partial.rename(destination.path);
    cancelToken.throwIfCancelled();
    await cache.store.putFile(
      CacheObject(
        url,
        key: url,
        relativePath: fileName,
        validTill: DateTime.now().add(const Duration(days: 30)),
        eTag: response.headers['etag'],
      ),
    );
    published = true;
    cancelToken.throwIfCancelled();
    return destination;
  } finally {
    try {
      await output?.close();
    } on Object {
      /* Preserve the original error. */
    }
    for (final file in [partial, if (!published) destination]) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        /* Best-effort temporary cleanup. */
      }
    }
  }
}

Future<void> openMediaExternally(BuildContext context, String url) async {
  try {
    final remote = remoteMediaUri(url);
    if (remote == null) throw const FormatException('媒体地址无效。');
    final uri = kIsWeb
        ? remote
        : Uri.file((await AppCacheManager.instance.getSingleFile(url)).path);
    if (!context.mounted) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const MediaSaveException('没有找到能够打开此文件的外部播放器。');
    }
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(formatMediaSaveError(error))));
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
  final url = previewUrl ?? highResUrl;
  if (url == null || isVideoUrl(url)) {
    return const Icon(Icons.image_not_supported_outlined);
  }
  return CachedMediaImage(
    imageUrl: url,
    width: width,
    height: height,
    fit: fit,
    errorBuilder: errorBuilder,
    maxDecodeDimension: 1024,
  );
}

class CachedMediaImage extends StatefulWidget {
  final String imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;
  final int maxDecodeDimension;
  final String? previewUrl;

  const CachedMediaImage({
    super.key,
    required this.imageUrl,
    required this.fit,
    this.width,
    this.height,
    this.errorBuilder,
    this.maxDecodeDimension = 4096,
    this.previewUrl,
  });

  @override
  State<CachedMediaImage> createState() => _CachedMediaImageState();
}

class _CachedMediaImageState extends State<CachedMediaImage> {
  late Future<ImageProvider> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = cachedMediaImageProvider(widget.imageUrl);
    AppNetworkService.instance.addListener(_reload);
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _imageFuture = cachedMediaImageProvider(widget.imageUrl));
  }

  @override
  void dispose() {
    AppNetworkService.instance.removeListener(_reload);
    super.dispose();
  }

  @override
  void didUpdateWidget(CachedMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _imageFuture = cachedMediaImageProvider(widget.imageUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ImageProvider>(
      key: ValueKey(widget.imageUrl),
      future: _imageFuture,
      builder: (context, snapshot) {
        final provider = snapshot.data;
        if (provider != null) {
          return Image(
            image: ResizeImage(
              provider,
              width: widget.maxDecodeDimension,
              height: widget.maxDecodeDimension,
              policy: ResizeImagePolicy.fit,
            ),
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: widget.errorBuilder,
          );
        }

        final preview = widget.previewUrl;
        if (preview != null && preview != widget.imageUrl) {
          return Stack(
            fit: StackFit.expand,
            children: [
              CachedMediaImage(
                imageUrl: preview,
                fit: widget.fit,
                width: widget.width,
                height: widget.height,
                maxDecodeDimension: 1024,
              ),
              if (snapshot.hasError)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: FilledButton.tonal(
                      onPressed: _reload,
                      child: const Text('原图加载失败，重试'),
                    ),
                  ),
                ),
              if (!snapshot.hasError)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(),
                ),
            ],
          );
        }
        if (snapshot.hasError) {
          return widget.errorBuilder?.call(context, snapshot.error!, null) ??
              const Icon(Icons.error);
        }

        return const Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
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
  final String? semanticLabel;
  final bool? selected;

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
    this.semanticLabel,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final image = Stack(
      fit: StackFit.expand,
      children: [
        Hero(
          tag: heroTag,
          child:
              previewUrl == null &&
                  (highResUrl == null || isVideoUrl(highResUrl!))
              ? Center(
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: errorIconSize ?? 32,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    semanticLabel: '暂无预览',
                  ),
                )
              : cachedHighResImageOrPreview(
                  highResUrl: highResUrl,
                  previewUrl: previewUrl,
                  width: width,
                  height: height,
                  fit: fit,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.broken_image_outlined,
                    size: errorIconSize,
                    semanticLabel: '预览加载失败',
                  ),
                ),
        ),
        if (overlay != null) overlay!,
      ],
    );

    final content = SizedBox(width: width, height: height, child: image);

    return Semantics(
      label: semanticLabel,
      selected: selected,
      button: onTap != null,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius ?? BorderRadius.circular(10),
          side: BorderSide(
            color: selected == true
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected == true ? 2 : 0.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, child: content),
      ),
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
    if (!supportsNativeMediaDrag) return;
    _dragTimer = Timer(const Duration(seconds: 1), () {
      _didStartDrag = true;
      if (mounted) startDrag(context, widget.media);
    });
  }

  void _finishHold() {
    final shouldSave =
        !supportsNativeMediaDrag ||
        (_dragTimer?.isActive == true && !_didStartDrag);
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
  return AppCacheManager.instance.getSingleFile(url);
}

/// 触发原生拖拽
/// [context] 用于 SnackBar 提示错误
/// [mediaUrl] 图片或视频 URL
Future<void> startDrag(BuildContext context, String media) async {
  if (media.isEmpty || !supportsNativeMediaDrag) return;

  final type = isVideoUrl(media) ? "video" : "image";
  String filePath;

  try {
    if (media.startsWith('http://') || media.startsWith('https://')) {
      // URL → 获取缓存文件（ugoira 压缩包先合并为 GIF）
      filePath = isUgoiraUrl(media)
          ? (await getUgoiraGifFile(media)).path
          : (await getCachedFile(media)).path;
    } else {
      // 本地文件路径
      filePath = media;
    }

    final started = await DragHelper.startDrag(filePath, type: type);
    if (!started) throw const MediaSaveException('系统未能开始拖拽，请使用保存按钮。');
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(formatMediaSaveError(e))));
  }
}

Future<void> saveMediaToGallery(BuildContext context, String mediaUrl) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _MediaSaveDialog(source: mediaUrl),
  );
}

class _MediaSaveDialog extends StatefulWidget {
  const _MediaSaveDialog({required this.source});
  final String source;
  @override
  State<_MediaSaveDialog> createState() => _MediaSaveDialogState();
}

class _MediaSaveDialogState extends State<_MediaSaveDialog> {
  final _cancel = NetworkCancelToken();
  bool _running = true;
  double? _progress;
  String _message = '正在下载并保存媒体…';

  @override
  void initState() {
    super.initState();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      final result = await saveMediaResource(
        widget.source,
        cancelToken: _cancel,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(
            () => _progress = total != null && total > 0
                ? (received / total).clamp(0.0, 1.0)
                : null,
          );
        },
      );
      if (mounted) setState(() => _message = result.destination);
    } catch (error) {
      if (mounted) setState(() => _message = formatMediaSaveError(error));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_running,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _running) _cancel.cancel();
    },
    child: AlertDialog(
      title: Text(_running ? '保存媒体' : '保存结果'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_running) ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 16),
          ],
          Text(_message),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _running ? _cancel.cancel : () => Navigator.pop(context),
          child: Text(_running ? '取消下载' : '完成'),
        ),
      ],
    ),
  );
}
