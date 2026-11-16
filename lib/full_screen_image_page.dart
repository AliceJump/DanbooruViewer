import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';

import 'media_image_frame.dart';
import 'media_utils.dart';
import 'media_video_session.dart';
import 'network/app_cache_manager.dart';
import 'network/app_network_service.dart';
import 'post.dart';
import 'video_controls.dart';

class FullScreenImagePage extends StatefulWidget {
  final String previewUrl;
  final String? highResUrl;
  final String heroTag;
  final List<Post>? posts;
  final int initialIndex;
  final MediaImageProviderLoader? imageProviderLoader;

  const FullScreenImagePage({
    super.key,
    required this.previewUrl,
    this.highResUrl,
    required this.heroTag,
    this.posts,
    this.initialIndex = 0,
    this.imageProviderLoader,
  });

  @override
  State<FullScreenImagePage> createState() => _FullScreenImagePageState();
}

class _FullScreenImagePageState extends State<FullScreenImagePage>
    with WidgetsBindingObserver {
  late int _index;
  final _video = MediaVideoSession();
  ImageProvider? _imageProvider;
  ImageProvider? _previewProvider;
  MediaImageFrame? _originalFrame;
  MediaImageFrame? _previewFrame;
  final _pendingImageFrames = <MediaImageFrame>{};
  String? _loadedSource;
  String? _loadedPreview;
  Object? _imageError;
  bool _loading = true;
  int _generation = 0;

  Post? get _post => widget.posts?.elementAtOrNull(_index);
  String? get _preview =>
      _post?.previewFileUrl ??
      (widget.posts == null && widget.previewUrl.isNotEmpty
          ? widget.previewUrl
          : null);
  String? get _source => _post == null
      ? widget.highResUrl ?? _preview
      : _post!.fileUrl ?? _post!.largeFileUrl ?? _preview;
  bool get _isVideo => _source != null && isVideoUrl(_source!);
  int get _count => widget.posts?.length ?? 1;
  String get _heroTag => _post == null ? widget.heroTag : 'post_${_post!.id}';

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    _video.addListener(_mediaChanged);
    AppNetworkService.instance.addListener(_reload);
    _load();
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) _video.pause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _video.pause();
  }

  @override
  void dispose() {
    _generation++;
    _cancelPendingImageFrames();
    _originalFrame?.dispose();
    _previewFrame?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    AppNetworkService.instance.removeListener(_reload);
    _video.removeListener(_mediaChanged);
    _video.dispose();
    super.dispose();
  }

  void _cancelPendingImageFrames() {
    for (final frame in _pendingImageFrames) {
      frame.dispose();
    }
    _pendingImageFrames.clear();
  }

  void _reload() {
    if (!mounted) return;
    _load();
  }

  Future<void> _retryImage() async {
    final generation = _generation;
    final source = _source;
    if (source == null) return;
    try {
      if (widget.imageProviderLoader == null) {
        await AppCacheManager.instance.removeFile(source);
      }
      if (mounted && generation == _generation) _load();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _imageError = error);
      }
    }
  }

  void _load() {
    final generation = ++_generation;
    final source = _source;
    final preview = _preview;
    final sameSource = source == _loadedSource && preview == _loadedPreview;
    _loadedSource = source;
    _loadedPreview = preview;
    _cancelPendingImageFrames();
    if (!sameSource) {
      _originalFrame?.dispose();
      _originalFrame = null;
      _previewFrame?.dispose();
      _previewFrame = null;
    }
    setState(() {
      if (!sameSource) {
        _imageProvider = null;
        _previewProvider = null;
      }
      _imageError = null;
      _loading = source != null;
    });
    unawaited(
      _video.setSource(
        _isVideo && supportsInlineVideo ? source : null,
        revision: AppNetworkService.instance.revision,
      ),
    );
    if (source == null) {
      setState(() => _imageError = const FormatException('作品没有可显示的媒体地址。'));
      return;
    }
    // Both requests use the same cache. A slow preview never blocks the original.
    if (preview != null && preview != source && _previewProvider == null) {
      unawaited(_loadImage(preview, generation, isOriginal: false));
    }
    if (!_isVideo) {
      unawaited(_loadImage(source, generation, isOriginal: true));
    }
  }

  Future<void> _loadImage(
    String url,
    int generation, {
    required bool isOriginal,
  }) async {
    MediaImageFrame? frame;
    var adopted = false;
    try {
      final provider =
          await (widget.imageProviderLoader ?? cachedMediaImageProvider)(url);
      if (!mounted || generation != _generation) return;
      frame = MediaImageFrame(provider);
      _pendingImageFrames.add(frame);
      if (!await frame.ready) {
        if (frame.error != null) throw frame.error!;
        return;
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        if (isOriginal) {
          _originalFrame?.dispose();
          _originalFrame = frame;
          _imageProvider = frame!.provider;
          _loading = false;
          _imageError = null;
        } else {
          _previewFrame?.dispose();
          _previewFrame = frame;
          _previewProvider = frame!.provider;
          _imageProvider ??= frame.provider;
        }
        adopted = true;
      });
    } catch (error) {
      if (!mounted || generation != _generation || !isOriginal) return;
      setState(() {
        _loading = false;
        _imageError = error;
      });
    } finally {
      _pendingImageFrames.remove(frame);
      if (!adopted) frame?.dispose();
    }
  }

  void _move(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= _count) return;
    _video.pause();
    _index = next;
    _load();
  }

  void _close() {
    _video.pause();
    Navigator.pop(context, _index);
  }

  Widget _error(String message, {VoidCallback? retry, bool external = false}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (retry != null)
                  FilledButton(onPressed: retry, child: const Text('重试')),
                if (external && _source != null)
                  OutlinedButton.icon(
                    onPressed: () => openMediaExternally(context, _source!),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('外部播放'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _media() {
    _originalFrame?.handoff();
    _previewFrame?.handoff();
    if (_isVideo) {
      if (!supportsInlineVideo) {
        return _error('当前平台使用外部播放器播放视频。媒体会先通过当前网络设置下载。', external: true);
      }
      final controller = _video.controller;
      if (controller != null) {
        return DanbooruVideoPlayer(controller: controller);
      }
      if (_video.error != null) {
        return _error(
          '视频加载失败。${formatMediaLoadError(_video.error!)}',
          retry: _reload,
          external: true,
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (_imageProvider == null) {
      return _imageError == null
          ? const Center(child: CircularProgressIndicator())
          : _error(formatMediaLoadError(_imageError!), retry: _retryImage);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        _VisibilityAwarePhotoView(
          key: ValueKey('$_index:$_generation'),
          imageProvider: _imageProvider!,
          heroTag: _heroTag,
          errorBuilder: (context, error, stack) =>
              _error(formatMediaLoadError(error), retry: _retryImage),
        ),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
        if (_imageError != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    const Text(
                      '原图加载失败，正在显示预览。',
                      style: TextStyle(color: Colors.white),
                    ),
                    TextButton(
                      onPressed: _retryImage,
                      child: const Text('重试原图'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
      },
      child: Focus(
        autofocus: true,
        child: PopScope<int>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _close();
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              leading: IconButton(
                tooltip: '关闭全屏 (Esc)',
                onPressed: _close,
                icon: const Icon(Icons.close),
              ),
              title: Text(
                _post == null ? '查看媒体' : '#${_post!.id}',
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  tooltip: '保存原图或视频',
                  onPressed: source == null
                      ? null
                      : () {
                          _video.pause();
                          saveMediaToGallery(context, source);
                        },
                  icon: const Icon(Icons.download_outlined),
                ),
              ],
            ),
            body: SafeArea(
              child: source == null
                  ? _media()
                  : TimedMediaHoldGesture(media: source, child: _media()),
            ),
            bottomNavigationBar: _count <= 1
                ? null
                : SafeArea(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '上一张 (←)',
                          color: Colors.white,
                          onPressed: _index == 0 ? null : () => _move(-1),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Flexible(
                          child: Text(
                            '${_index + 1} / $_count',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        IconButton(
                          tooltip: '下一张 (→)',
                          color: Colors.white,
                          onPressed: _index + 1 >= _count
                              ? null
                              : () => _move(1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// PhotoView owns an image listener that does not follow TickerMode. Keep only
/// its view values while hidden so neither that listener nor its controllers
/// survive the hidden child. The image frame itself is retained by the page.
class _VisibilityAwarePhotoView extends StatefulWidget {
  const _VisibilityAwarePhotoView({
    super.key,
    required this.imageProvider,
    required this.heroTag,
    required this.errorBuilder,
  });

  final ImageProvider imageProvider;
  final String heroTag;
  final ImageErrorWidgetBuilder errorBuilder;

  @override
  State<_VisibilityAwarePhotoView> createState() =>
      _VisibilityAwarePhotoViewState();
}

class _VisibilityAwarePhotoViewState extends State<_VisibilityAwarePhotoView> {
  PhotoViewController? _controller;
  PhotoViewScaleStateController? _scaleStateController;
  PhotoViewControllerValue? _savedValue;
  PhotoViewScaleState _savedScaleState = PhotoViewScaleState.initial;
  bool _visible = true;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.of(context);
    if (!_visible) _releaseControllers(preserveView: true);
  }

  @override
  void didUpdateWidget(_VisibilityAwarePhotoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageProvider != oldWidget.imageProvider) {
      // A preview and its original can have different pixel dimensions. Never
      // apply the preview's pixel scale or offset to the replacement image.
      _savedValue = null;
      _savedScaleState = PhotoViewScaleState.initial;
      _releaseControllers(preserveView: false);
      _generation++;
    }
  }

  void _releaseControllers({required bool preserveView}) {
    final controller = _controller;
    final scaleStateController = _scaleStateController;
    if (controller == null || scaleStateController == null) return;
    if (preserveView) {
      _savedValue = controller.value;
      _savedScaleState = scaleStateController.scaleState;
    }
    _controller = null;
    _scaleStateController = null;
    // Let the old PhotoView detach before closing the controllers. New ones
    // avoid PhotoView 0.15 retaining output-stream listeners across remounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
      scaleStateController.dispose();
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _scaleStateController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.expand();
    _controller ??= PhotoViewController(
      initialPosition: _savedValue?.position ?? Offset.zero,
      initialScale: _savedValue?.scale,
      initialRotation: _savedValue?.rotation ?? 0,
    );
    _scaleStateController ??= PhotoViewScaleStateController()
      ..setInvisibly(_savedScaleState);
    return PhotoView(
      key: ValueKey(_generation),
      imageProvider: widget.imageProvider,
      heroAttributes: PhotoViewHeroAttributes(tag: widget.heroTag),
      controller: _controller,
      scaleStateController: _scaleStateController,
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4,
      loadingBuilder: (context, event) =>
          const Center(child: CircularProgressIndicator()),
      errorBuilder: widget.errorBuilder,
    );
  }
}
