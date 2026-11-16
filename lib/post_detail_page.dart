import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'completion_normalization.dart';
import 'completion_service.dart';
import 'favorites_manager.dart';
import 'full_screen_image_page.dart';
import 'main.dart' show SearchChip;
import 'media_utils.dart';
import 'media_video_session.dart';
import 'network/app_network_service.dart';
import 'post.dart';
import 'ugoira_utils.dart';
import 'video_controls.dart';

class PostDetailPage extends StatefulWidget {
  final List<Post> posts;
  final int initialIndex;
  final Map<String, String> completionDisplayByValue;
  final Map<String, int> completionCategoryByValue;
  final CompletionService? completionService;
  final Future<bool> Function(int)? isFavoriteLookup;
  final VideoPlayerController Function(Uri)? videoControllerFactory;

  const PostDetailPage({
    super.key,
    required this.posts,
    required this.initialIndex,
    required this.completionDisplayByValue,
    this.completionCategoryByValue = const {},
    this.completionService,
    this.isFavoriteLookup,
    this.videoControllerFactory,
  });

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

Future<Object?> openPostDetailPage({
  required BuildContext context,
  required List<Post> posts,
  required int initialIndex,
  required Map<String, String> completionDisplayByValue,
  Map<String, int> completionCategoryByValue = const {},
  CompletionService? completionService,
}) {
  if (initialIndex >= 0 && initialIndex < posts.length) {
    final post = posts[initialIndex];
    warmPostImages(
      previewUrl: post.previewFileUrl,
      highResUrl: post.fileUrl ?? post.largeFileUrl,
    );
  }

  return Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => PostDetailPage(
        posts: posts,
        initialIndex: initialIndex,
        completionDisplayByValue: completionDisplayByValue,
        completionCategoryByValue: completionCategoryByValue,
        completionService: completionService,
      ),
    ),
  );
}

class _PostDetailPageState extends State<PostDetailPage>
    with WidgetsBindingObserver {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, String> _commentaryByPostId = {};
  final Map<int, Future<String?>> _commentaryRequests = {};
  final _commentaryCancel = NetworkCancelToken();
  late final MediaVideoSession _video;
  bool _openingFullScreen = false;
  bool _didChangeDependenciesRun = false;
  final Map<String, CompletionTagInfo> _completionMetadata = {};
  final Set<String> _requestedMetadata = {};

  final _favoritesManager = FavoritesManager();
  bool _isFavorite = false;
  int _favoriteRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _video = MediaVideoSession(controllerFactory: widget.videoControllerFactory)
      ..addListener(_mediaChanged);
    WidgetsBinding.instance.addObserver(this);
    AppNetworkService.instance.addListener(_networkChanged);
    _checkFavoriteStatus();
    _recordCurrentPostHistory();
    _loadTagMetadata(_currentIndex);
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  void _networkChanged() {
    if (mounted) _loadMediaForIndex(_currentIndex);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _video.pause();
  }

  Future<void> _loadTagMetadata(int index) async {
    final service = widget.completionService;
    if (service == null || index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    final tags = <String>{
      for (final text in [
        post.tagString,
        post.tagStringGeneral,
        post.tagStringArtist,
        post.tagStringCharacter,
        post.tagStringCopyright,
        post.tagStringMeta,
      ])
        if (text != null)
          ...text
              .split(' ')
              .where((tag) => tag.isNotEmpty)
              .map(normalizeCompletionKey),
    }.where((tag) => !_requestedMetadata.contains(tag)).toList();
    if (tags.isEmpty) return;
    _requestedMetadata.addAll(tags);
    try {
      final metadata = await service.lookup(tags);
      if (!mounted) return;
      setState(() => _completionMetadata.addAll(metadata));
    } catch (e) {
      _requestedMetadata.removeAll(tags);
      debugPrint('Failed to load post tag labels: $e');
    }
  }

  int? _categoryForTag(String tag) {
    final key = normalizeCompletionKey(tag);
    final metadataCategory =
        _completionMetadata[key]?.category ??
        widget.completionCategoryByValue[key];
    if (metadataCategory != null) return metadataCategory;
    final post = widget.posts[_currentIndex];
    final groups = <int, String?>{
      0: post.tagStringGeneral,
      1: post.tagStringArtist,
      3: post.tagStringCopyright,
      4: post.tagStringCharacter,
      5: post.tagStringMeta,
    };
    for (final group in groups.entries) {
      if (group.value
              ?.split(' ')
              .any((value) => normalizeCompletionKey(value) == key) ??
          false) {
        return group.key;
      }
    }
    return null;
  }

  Future<void> _checkFavoriteStatus() async {
    final currentPost = widget.posts[_currentIndex];
    final requestGeneration = ++_favoriteRequestGeneration;
    final isFav =
        await (widget.isFavoriteLookup?.call(currentPost.id) ??
            _favoritesManager.isFavorite(currentPost.id));
    if (mounted && requestGeneration == _favoriteRequestGeneration) {
      setState(() {
        _isFavorite = isFav;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppNetworkService.instance.removeListener(_networkChanged);
    _video.removeListener(_mediaChanged);
    _video.dispose();
    _commentaryCancel.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) _video.pause();
    if (!_didChangeDependenciesRun) {
      _loadMediaForIndex(_currentIndex, prioritizePreview: true);
      _didChangeDependenciesRun = true;
    }
  }

  Future<void> _loadMediaForIndex(
    int index, {
    bool prioritizePreview = false,
  }) async {
    if (_openingFullScreen || index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    unawaited(_prefetchCommentary(post));
    final source = post.fileUrl ?? post.largeFileUrl;
    await _video.setSource(
      source != null &&
              isVideoUrl(source) &&
              (supportsInlineVideo || widget.videoControllerFactory != null)
          ? source
          : null,
      revision: AppNetworkService.instance.revision,
    );
  }

  Future<void> _openFullScreen(int index) async {
    if (_openingFullScreen) return;
    _openingFullScreen = true;
    // Release the detail decoder before the full-screen route takes ownership.
    _video.pause();
    await _video.setSource(null);
    if (!mounted) return;
    final post = widget.posts[index];
    final result = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (context) => FullScreenImagePage(
          previewUrl: post.previewFileUrl ?? '',
          highResUrl: post.fileUrl ?? post.largeFileUrl,
          heroTag: 'post_${post.id}',
          posts: widget.posts,
          initialIndex: index,
        ),
      ),
    );
    if (!mounted) return;
    _openingFullScreen = false;
    if (result != null &&
        result >= 0 &&
        result < widget.posts.length &&
        result != _currentIndex) {
      _pageController.jumpToPage(result);
    } else {
      unawaited(_loadMediaForIndex(_currentIndex));
    }
  }

  void _movePage(int delta) {
    final next = _currentIndex + delta;
    if (next < 0 || next >= widget.posts.length) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _isFavorite = false;
    });
    _loadMediaForIndex(index, prioritizePreview: true);
    _checkFavoriteStatus();
    _recordCurrentPostHistory();
    _loadTagMetadata(index);
  }

  Future<void> _recordCurrentPostHistory() async {
    await _favoritesManager.addBrowsingHistory(
      widget.posts[_currentIndex].toJson(),
    );
  }

  Future<void> _toggleFavorite() async {
    final currentPost = widget.posts[_currentIndex];
    final requestGeneration = ++_favoriteRequestGeneration;
    final newState = await _favoritesManager.toggleFavorite(
      currentPost.toJson(),
    );
    if (mounted && requestGeneration == _favoriteRequestGeneration) {
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
    final category = _categoryForTag(tag);
    final newState = await _favoritesManager.toggleFavoriteTag(
      tag,
      category: category,
    );
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

  void _copyLink(String url, String label) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制$label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _sharePost(Post post) async {
    _video.pause();
    final intro = await _postIntro(post).timeout(
      const Duration(milliseconds: 1200),
      onTimeout: () => _fallbackPostIntro(post),
    );
    if (!mounted) return;
    final postUrl = _postUrl(post);
    final text = intro == null || intro.isEmpty
        ? postUrl
        : '$postUrl\n\n$intro';
    try {
      final box = context.findRenderObject() as RenderBox?;
      await Share.share(
        text,
        subject: 'Danbooru Post #${post.id}',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('系统分享不可用，已复制作品链接和简介。')));
    }
  }

  Future<String?> _postIntro(Post post) {
    final cached = _commentaryByPostId[post.id];
    if (cached != null) return Future.value(cached.isEmpty ? null : cached);
    final pending = _commentaryRequests[post.id];
    if (pending != null) return pending;
    late Future<String?> request;
    request =
        (() async {
          try {
            final persisted = await _favoritesManager.getCachedCommentary(
              post.id,
            );
            if (persisted != null) {
              _commentaryByPostId[post.id] = persisted;
              return persisted.isEmpty ? null : persisted;
            }
            final commentary = await _fetchArtistCommentary(post.id);
            if (commentary != null) {
              _commentaryByPostId[post.id] = commentary;
              await _favoritesManager.setCachedCommentary(post.id, commentary);
            }
            return commentary ?? _fallbackPostIntro(post);
          } on Object {
            return _fallbackPostIntro(post);
          } finally {
            while (_commentaryByPostId.length > 80) {
              _commentaryByPostId.remove(_commentaryByPostId.keys.first);
            }
          }
        })().whenComplete(() {
          if (identical(_commentaryRequests[post.id], request)) {
            _commentaryRequests.remove(post.id);
          }
        });
    _commentaryRequests[post.id] = request;
    return request;
  }

  Future<void> _prefetchCommentary(Post post) async {
    if (_commentaryByPostId.containsKey(post.id) ||
        _commentaryRequests.length >= 2) {
      return;
    }
    await _postIntro(post);
  }

  Future<String?> _fetchArtistCommentary(int postId) async {
    try {
      final uri = Uri.https('danbooru.donmai.us', '/artist_commentaries.json', {
        'search[post_id]': '$postId',
        'limit': '1',
      });
      final response = await AppNetworkService.instance.get(
        uri,
        cancelToken: _commentaryCancel,
        timeout: const Duration(seconds: 3),
        retry: false,
      );
      if (response.statusCode != 200) return null;

      final payload = json.decode(response.body);
      if (payload is! List || payload.isEmpty || payload.first is! Map) {
        return null;
      }

      final commentary = Map<String, dynamic>.from(payload.first as Map);
      final title = _firstNonEmpty([
        commentary['translated_title'],
        commentary['original_title'],
      ]);
      final description = _firstNonEmpty([
        commentary['translated_description'],
        commentary['original_description'],
      ]);

      return [title, description]
          .whereType<String>()
          .map(_normalizeShareText)
          .where((value) => value.isNotEmpty)
          .join('\n');
    } catch (e) {
      debugPrint('Failed to load artist commentary for post $postId: $e');
      return null;
    }
  }

  String? _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  String _normalizeShareText(String text) {
    return text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  String? _fallbackPostIntro(Post post) {
    final lines = [
      if (post.tagStringArtist?.trim().isNotEmpty == true)
        '作者: ${post.tagStringArtist}',
      if (post.tagStringCopyright?.trim().isNotEmpty == true)
        '版权: ${post.tagStringCopyright}',
      if (post.tagStringCharacter?.trim().isNotEmpty == true)
        '角色: ${post.tagStringCharacter}',
      if (post.rating.trim().isNotEmpty) 'Rating: ${post.rating}',
    ];
    if (lines.isEmpty) return null;
    return lines.join('\n');
  }

  Widget _buildTagSection(String title, String? tags, BuildContext context) {
    if (tags == null || tags.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final tagList = tags.trim().split(' ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: tagList.map((tag) {
              final displayLabel = _displayLabelForTag(tag);
              return GestureDetector(
                onLongPress: () => _showTagMenu(context, tag),
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
        ],
      ),
    );
  }

  String _displayLabelForTag(String tag) {
    final key = normalizeCompletionKey(tag);
    return _completionMetadata[key]?.label ??
        widget.completionDisplayByValue[key] ??
        tag;
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
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
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
    return remoteMediaUri(uri.hasScheme ? value : 'https://$value');
  }

  String _postUrl(Post post) {
    return 'https://danbooru.donmai.us/posts/${post.id}';
  }

  String? _sourceUrl(Post post) {
    final source = post.source?.trim();
    if (source == null || source.isEmpty) return null;
    return _normalizeUrl(_normalizePixivSource(source))?.toString();
  }

  String _normalizePixivSource(String source) {
    final pixivIdPatterns = [
      RegExp(r'pixiv[./].*?[?&]illust_id=(\d+)', caseSensitive: false),
      RegExp(r'pixiv[./].*?/artworks/(\d+)', caseSensitive: false),
      RegExp(r'pixiv[./].*?/i/(\d+)', caseSensitive: false),
      RegExp(r'pixiv[./].*?/img-original/.*/(\d+)_p\d+', caseSensitive: false),
      RegExp(r'pximg\.net/.*/(\d+)_p\d+', caseSensitive: false),
    ];

    for (final pattern in pixivIdPatterns) {
      final match = pattern.firstMatch(source);
      if (match != null) {
        return 'https://www.pixiv.net/artworks/${match.group(1)}';
      }
    }
    return source;
  }

  Widget _buildLinkButtons(Post post) {
    final sourceUrl = _sourceUrl(post);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: () => _launchUrl(_postUrl(post)),
            onLongPress: () => _copyLink(_postUrl(post), '站内原链接'),
            icon: const Icon(Icons.open_in_new),
            label: const Text('站内原链接'),
          ),
          if (sourceUrl != null)
            OutlinedButton.icon(
              onPressed: () => _launchUrl(sourceUrl),
              onLongPress: () => _copyLink(sourceUrl, '源链接'),
              icon: const Icon(Icons.link),
              label: Text(
                _isPixivSource(sourceUrl) ? 'Pixiv 源链接' : 'Source 源链接',
              ),
            ),
        ],
      ),
    );
  }

  bool _isPixivSource(String source) {
    return source.toLowerCase().contains('pixiv.net');
  }

  double _portraitMediaHeight(Post post, Size screenSize) {
    final imageWidth = post.imageWidth;
    final imageHeight = post.imageHeight;
    if (imageWidth == null || imageHeight == null || imageWidth <= 0) {
      return screenSize.height * 0.5;
    }

    final naturalHeight = screenSize.width * imageHeight / imageWidth;
    return naturalHeight.clamp(
      screenSize.height * 0.32,
      screenSize.height * 0.72,
    );
  }

  Widget _buildMediaPager(double height) {
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.posts.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final post = widget.posts[index];
              final original = post.fileUrl ?? post.largeFileUrl;
              final video = original != null && isVideoUrl(original);
              final source = video || isUgoiraUrl(original)
                  ? original
                  : post.largeFileUrl ?? original ?? post.previewFileUrl;
              final controller = index == _currentIndex
                  ? _video.controller
                  : null;
              final inlineVideo =
                  supportsInlineVideo || widget.videoControllerFactory != null;
              Widget media;
              if (video && controller != null) {
                media = Center(
                  child: DanbooruVideoPlayer(
                    controller: controller,
                    compact: true,
                    onOpenFullScreen: () => _openFullScreen(index),
                  ),
                );
              } else if (video && inlineVideo && _video.error == null) {
                media = const Center(child: CircularProgressIndicator());
              } else if (video) {
                media = Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (inlineVideo && _video.error == null)
                          const CircularProgressIndicator()
                        else ...[
                          Text(
                            inlineVideo
                                ? '视频加载失败。${formatMediaLoadError(_video.error!)}'
                                : '当前平台使用外部播放器播放视频。',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              if (inlineVideo)
                                TextButton(
                                  onPressed: () => _loadMediaForIndex(index),
                                  child: const Text('重试'),
                                ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    openMediaExternally(context, source!),
                                icon: const Icon(Icons.open_in_new),
                                label: const Text('外部播放'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              } else if (source == null) {
                media = const Center(
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    semanticLabel: '作品没有可显示的媒体',
                  ),
                );
              } else {
                media = Hero(
                  tag: 'post_${post.id}',
                  child: CachedMediaImage(
                    imageUrl: source,
                    previewUrl: post.previewFileUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formatMediaLoadError(error),
                              textAlign: TextAlign.center,
                            ),
                            TextButton(
                              onPressed: () => _openFullScreen(index),
                              child: const Text('打开并重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }
              if (source != null) {
                media = TimedMediaHoldGesture(
                  media: original ?? source,
                  child: media,
                );
              }
              return GestureDetector(
                onTap: source == null ? null : () => _openFullScreen(index),
                child: media,
              );
            },
          ),
          if (widget.posts.length > 1) ...[
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filledTonal(
                  tooltip: '上一张 (←)',
                  onPressed: _currentIndex == 0 ? null : () => _movePage(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filledTonal(
                  tooltip: '下一张 (→)',
                  onPressed: _currentIndex + 1 >= widget.posts.length
                      ? null
                      : () => _movePage(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoPanel(Post post) {
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('作品信息', style: Theme.of(context).textTheme.titleMedium),
        ),
        _buildLinkButtons(post),
        _buildTagSection('作者', post.tagStringArtist, context),
        _buildTagSection('版权', post.tagStringCopyright, context),
        _buildTagSection('角色', post.tagStringCharacter, context),
        _buildTagSection('普通', post.tagStringGeneral, context),
      ],
    );
  }

  void _savePost(Post post) {
    final source = post.fileUrl ?? post.largeFileUrl;
    if (source == null) return;
    _video.pause();
    saveMediaToGallery(context, source);
  }

  @override
  Widget build(BuildContext context) {
    final currentPostForTags = widget.posts[_currentIndex];
    final orientation = MediaQuery.orientationOf(context);
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = orientation == Orientation.landscape;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _movePage(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _movePage(1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              'Post #${currentPostForTags.id}',
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (screenSize.width >= 360)
                IconButton(
                  icon: const Icon(Icons.download_outlined),
                  tooltip: '保存原图或视频',
                  onPressed:
                      currentPostForTags.fileUrl == null &&
                          currentPostForTags.largeFileUrl == null
                      ? null
                      : () => _savePost(currentPostForTags),
                ),
              IconButton(
                icon: Icon(
                  _isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: _isFavorite
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: _toggleFavorite,
                tooltip: _isFavorite ? '取消收藏' : '收藏',
              ),
              if (screenSize.width >= 360)
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () => _sharePost(currentPostForTags),
                  tooltip: '分享',
                ),
              if (screenSize.width < 360)
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  onSelected: (action) {
                    if (action == 'save') _savePost(currentPostForTags);
                    if (action == 'share') _sharePost(currentPostForTags);
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'save',
                      enabled:
                          currentPostForTags.fileUrl != null ||
                          currentPostForTags.largeFileUrl != null,
                      child: const Text('保存原图或视频'),
                    ),
                    const PopupMenuItem(value: 'share', child: Text('分享')),
                  ],
                ),
            ],
          ),
          body: SafeArea(
            child: Flex(
              direction: isLandscape ? Axis.horizontal : Axis.vertical,
              children: [
                Expanded(
                  flex: isLandscape ? 3 : 1,
                  child: _buildMediaPager(
                    isLandscape
                        ? screenSize.height
                        : _portraitMediaHeight(currentPostForTags, screenSize),
                  ),
                ),
                if (isLandscape)
                  const VerticalDivider(width: 1)
                else
                  const Divider(height: 1),
                Expanded(
                  flex: isLandscape ? 2 : 1,
                  child: _buildInfoPanel(currentPostForTags),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
