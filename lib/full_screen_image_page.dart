import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';

import 'media_utils.dart';
import 'media_video_session.dart';
import 'network/app_network_service.dart';
import 'post.dart';
import 'video_controls.dart';

class FullScreenImagePage extends StatefulWidget {
  final String previewUrl;
  final String? highResUrl;
  final String heroTag;
  final List<Post>? posts;
  final int initialIndex;

  const FullScreenImagePage({
    super.key,
    required this.previewUrl,
    this.highResUrl,
    required this.heroTag,
    this.posts,
    this.initialIndex = 0,
  });

  @override
  State<FullScreenImagePage> createState() => _FullScreenImagePageState();
}

class _FullScreenImagePageState extends State<FullScreenImagePage>
    with WidgetsBindingObserver {
  late int _index;
  final _video = MediaVideoSession();
  ImageProvider? _imageProvider;
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
    WidgetsBinding.instance.removeObserver(this);
    AppNetworkService.instance.removeListener(_reload);
    _video.removeListener(_mediaChanged);
    _video.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    _load();
  }

  void _load() {
    final generation = ++_generation;
    final source = _source;
    setState(() {
      _imageProvider = null;
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
    final preview = _preview;
    if (preview != null && preview != source) {
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
    try {
      final provider = await cachedMediaImageProvider(url);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (isOriginal || _imageProvider == null) _imageProvider = provider;
        if (isOriginal) {
          _loading = false;
          _imageError = null;
        }
      });
    } catch (error) {
      if (!mounted || generation != _generation || !isOriginal) return;
      setState(() {
        _loading = false;
        _imageError = error;
      });
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
          : _error(formatMediaLoadError(_imageError!), retry: _reload);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        PhotoView(
          key: ValueKey('$_index:$_generation'),
          imageProvider: _imageProvider,
          heroAttributes: PhotoViewHeroAttributes(tag: _heroTag),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 4,
          loadingBuilder: (context, event) =>
              const Center(child: CircularProgressIndicator()),
          errorBuilder: (context, error, stack) =>
              _error(formatMediaLoadError(error), retry: _reload),
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
                    TextButton(onPressed: _reload, child: const Text('重试原图')),
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
