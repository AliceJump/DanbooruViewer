import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
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
import 'post_filter.dart';
import 'tag_blocklist.dart';
import 'tag_blocklist_page.dart';
import 'ugoira_utils.dart';
import 'video_controls.dart';

Future<void> _undoPostTagBlock(
  ScaffoldMessengerState messenger,
  TagBlocklist store,
  Set<String> added, {
  required bool wasEnabled,
  required bool wasTemporarilyShowing,
}) async {
  try {
    if (added.isNotEmpty) await store.removeTags(added);
    if (!wasEnabled) await store.setEnabled(false);
    if (wasTemporarilyShowing) store.setTemporarilyShow(true);
  } catch (_) {
    if (messenger.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('撤销未能保存，请在标签屏蔽设置中重试。')),
      );
    }
  }
}

class PostDetailPage extends StatefulWidget {
  final List<Post> posts;
  final int initialIndex;
  final Map<String, String> completionDisplayByValue;
  final Map<String, int> completionCategoryByValue;
  final CompletionService? completionService;
  final Future<bool> Function(int)? isFavoriteLookup;
  final VideoPlayerController Function(Uri)? videoControllerFactory;
  final TagBlocklist? blocklist;
  final FavoritesManager? favoritesManager;

  const PostDetailPage({
    super.key,
    required this.posts,
    required this.initialIndex,
    required this.completionDisplayByValue,
    this.completionCategoryByValue = const {},
    this.completionService,
    this.isFavoriteLookup,
    this.videoControllerFactory,
    this.blocklist,
    this.favoritesManager,
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
  TagBlocklist? blocklist,
}) {
  final store = blocklist ?? TagBlocklistScope.of(context);
  if (initialIndex >= 0 && initialIndex < posts.length) {
    final post = posts[initialIndex];
    if (store.loaded && !store.hides(postTagsForBlocking(post))) {
      warmPostImages(
        previewUrl: post.previewFileUrl,
        highResUrl: post.fileUrl ?? post.largeFileUrl,
      );
    }
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
        blocklist: store,
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
  TagBlocklist? _blocklist;
  List<Post> _posts = const [];
  int? _selectedPostId;
  int _pagerGeneration = 0;
  bool _historyWarningShown = false;
  bool _blockingTag = false;
  final Map<String, CompletionTagInfo> _completionMetadata = {};
  final Set<String> _requestedMetadata = {};

  FavoritesManager get _favoritesManager =>
      widget.favoritesManager ?? FavoritesManager();
  Post? get _currentPost => _posts.elementAtOrNull(_currentIndex);
  bool _isFavorite = false;
  bool _favoriteWritePending = false;
  int _favoriteRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = 0;
    final initial =
        widget.initialIndex >= 0 && widget.initialIndex < widget.posts.length
        ? widget.posts[widget.initialIndex]
        : widget.posts.firstOrNull;
    _selectedPostId = initial?.id;
    _pageController = PageController();
    _video = MediaVideoSession(controllerFactory: widget.videoControllerFactory)
      ..addListener(_mediaChanged);
    WidgetsBinding.instance.addObserver(this);
    AppNetworkService.instance.addListener(_networkChanged);
  }

  @override
  void didUpdateWidget(PostDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blocklist != widget.blocklist) {
      _bindBlocklist(widget.blocklist ?? TagBlocklistScope.of(context));
    } else if (!identical(oldWidget.posts, widget.posts)) {
      _applyBlocklist();
    }
  }

  void _bindBlocklist(TagBlocklist store) {
    if (identical(store, _blocklist)) return;
    _blocklist?.removeListener(_applyBlocklist);
    _blocklist = store;
    store.addListener(_applyBlocklist);
    _applyBlocklist();
    unawaited(store.initialize());
  }

  void _applyBlocklist() {
    if (!mounted || _blocklist == null) return;
    final previous = _currentPost;
    final filtered = filterPostList(
      widget.posts,
      _blocklist!,
      selectedPostId: _selectedPostId,
      initialIndex: widget.initialIndex,
    );
    final next = filtered.posts.elementAtOrNull(filtered.index);
    final changed = previous?.id != next?.id;
    final sourceChanged =
        previous?.fileUrl != next?.fileUrl ||
        previous?.largeFileUrl != next?.largeFileUrl ||
        previous?.previewFileUrl != next?.previewFileUrl;
    final pagesChanged = !listEquals(
      _posts.map((post) => post.id).toList(),
      filtered.posts.map((post) => post.id).toList(),
    );
    if (changed || sourceChanged) {
      _video.pause();
      unawaited(_video.setSource(null));
    }
    if (changed) _favoriteRequestGeneration++;
    setState(() {
      _posts = filtered.posts;
      _currentIndex = filtered.index;
      _selectedPostId = next?.id ?? _selectedPostId;
      if (changed) _isFavorite = false;
      if (pagesChanged) {
        _pagerGeneration++;
        _pageController.dispose();
        _pageController = PageController(initialPage: _currentIndex);
      }
    });
    if (changed && next != null) _loadCurrentPost();
    if (!changed && sourceChanged && next != null) {
      unawaited(_loadMediaForIndex(_currentIndex));
    }
  }

  void _loadCurrentPost() {
    if (_currentPost == null) return;
    unawaited(_loadMediaForIndex(_currentIndex));
    unawaited(_checkFavoriteStatus());
    unawaited(_recordCurrentPostHistory());
    unawaited(_loadTagMetadata(_currentIndex));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || messenger?.mounted != true) return;
      messenger!.showSnackBar(SnackBar(content: Text(message)));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
    if (service == null || index < 0 || index >= _posts.length) return;
    final post = _posts[index];
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
              .split(RegExp(r'\s+'))
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
    final post = _currentPost;
    if (post == null) return null;
    final groups = <int, String?>{
      0: post.tagStringGeneral,
      1: post.tagStringArtist,
      3: post.tagStringCopyright,
      4: post.tagStringCharacter,
      5: post.tagStringMeta,
    };
    for (final group in groups.entries) {
      if (group.value
              ?.split(RegExp(r'\s+'))
              .any((value) => normalizeCompletionKey(value) == key) ??
          false) {
        return group.key;
      }
    }
    return null;
  }

  Future<void> _checkFavoriteStatus() async {
    final currentPost = _currentPost;
    if (currentPost == null) return;
    final requestGeneration = ++_favoriteRequestGeneration;
    try {
      final isFav =
          await (widget.isFavoriteLookup?.call(currentPost.id) ??
              _favoritesManager.isFavorite(currentPost.id));
      if (mounted && requestGeneration == _favoriteRequestGeneration) {
        setState(() => _isFavorite = isFav);
      }
    } catch (_) {
      if (requestGeneration == _favoriteRequestGeneration) {
        _showMessage('收藏状态无法读取，原始数据已保留。');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppNetworkService.instance.removeListener(_networkChanged);
    _video.removeListener(_mediaChanged);
    _video.dispose();
    _commentaryCancel.cancel();
    _blocklist?.removeListener(_applyBlocklist);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) _video.pause();
    _bindBlocklist(widget.blocklist ?? TagBlocklistScope.of(context));
  }

  Future<void> _loadMediaForIndex(int index) async {
    if (_openingFullScreen || index < 0 || index >= _posts.length) return;
    final post = _posts[index];
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

  Future<void> _openFullScreen(int postId) async {
    if (!mounted ||
        _openingFullScreen ||
        !_posts.any((post) => post.id == postId)) {
      return;
    }
    _openingFullScreen = true;
    _video.pause();
    await _video.setSource(null);
    if (!mounted) return;
    // Rules can change while an old decoder is still finishing disposal.
    final visibleIndex = _posts.indexWhere((post) => post.id == postId);
    if (visibleIndex < 0) {
      _openingFullScreen = false;
      unawaited(_loadMediaForIndex(_currentIndex));
      return;
    }
    final post = _posts[visibleIndex];
    final resultPostId = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (context) => FullScreenImagePage(
          previewUrl: post.previewFileUrl ?? '',
          highResUrl: post.fileUrl ?? post.largeFileUrl,
          heroTag: 'post_${post.id}',
          posts: widget.posts,
          initialIndex: widget.posts.indexWhere(
            (candidate) => candidate.id == post.id,
          ),
          blocklist: _blocklist,
          videoControllerFactory: widget.videoControllerFactory,
        ),
      ),
    );
    if (!mounted) return;
    _openingFullScreen = false;
    final resultIndex = _posts.indexWhere((post) => post.id == resultPostId);
    if (resultIndex >= 0 && resultIndex != _currentIndex) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(resultIndex);
      } else {
        // A rule update may have restored the pager, but its first frame has
        // not attached yet. Preserve the returned ID before that frame.
        _pagerGeneration++;
        _pageController.dispose();
        _pageController = PageController(initialPage: resultIndex);
        _onPageChanged(resultIndex);
      }
    } else {
      unawaited(_loadMediaForIndex(_currentIndex));
    }
  }

  void _movePage(int delta) {
    if (!_pageController.hasClients) return;
    final next = _currentIndex + delta;
    if (next < 0 || next >= _posts.length) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int index) {
    if (index < 0 || index >= _posts.length || index == _currentIndex) return;
    _video.pause();
    setState(() {
      _currentIndex = index;
      _selectedPostId = _posts[index].id;
      _isFavorite = false;
    });
    _loadCurrentPost();
  }

  Future<void> _recordCurrentPostHistory() async {
    final post = _currentPost;
    if (post == null) return;
    try {
      await _favoritesManager.addBrowsingHistory(post.toJson());
      _historyWarningShown = false;
    } catch (_) {
      if (!_historyWarningShown) {
        _historyWarningShown = true;
        _showMessage('浏览历史未能保存，本次浏览仍可继续。');
      }
    }
  }

  Future<void> _toggleFavorite(int postId) async {
    final currentPost = _currentPost;
    if (!mounted ||
        _favoriteWritePending ||
        currentPost == null ||
        currentPost.id != postId) {
      return;
    }
    setState(() => _favoriteWritePending = true);
    final requestGeneration = ++_favoriteRequestGeneration;
    try {
      final newState = await _favoritesManager.toggleFavorite(
        currentPost.toJson(),
      );
      if (mounted && requestGeneration == _favoriteRequestGeneration) {
        setState(() => _isFavorite = newState);
        _showMessage(newState ? '已添加到收藏' : '已取消收藏');
      }
    } catch (error) {
      _showMessage(
        error is LegacyFavoritesRecoveryException
            ? error.toString()
            : '收藏未能保存，原有收藏保持不变，请重试。',
      );
    } finally {
      if (mounted) setState(() => _favoriteWritePending = false);
    }
  }

  Future<void> _toggleFavoriteTag(String tag) async {
    final category = _categoryForTag(tag);
    try {
      final newState = await _favoritesManager.toggleFavoriteTag(
        tag,
        category: category,
      );
      _showMessage(newState ? '已收藏标签: $tag' : '已取消收藏标签: $tag');
    } catch (_) {
      _showMessage('标签收藏未能保存，原有收藏保持不变，请重试。');
    }
  }

  Future<void> _blockTag(String tag) async {
    final store = _blocklist;
    if (store == null || _blockingTag) return;
    final canonical = TagBlocklist.canonicalTag(tag);
    final messenger = ScaffoldMessenger.of(context);
    final wasEnabled = store.enabled;
    final wasTemporarilyShowing = store.temporarilyShow;
    setState(() => _blockingTag = true);
    try {
      final added = await store.addTags([canonical], enableFiltering: true);
      if (!messenger.mounted) return;
      messenger.removeCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('已屏蔽标签：$canonical'),
          action: added.isEmpty && wasEnabled && !wasTemporarilyShowing
              ? null
              : SnackBarAction(
                  label: '撤销',
                  onPressed: () => unawaited(
                    _undoPostTagBlock(
                      messenger,
                      store,
                      added,
                      wasEnabled: wasEnabled,
                      wasTemporarilyShowing: wasTemporarilyShowing,
                    ),
                  ),
                ),
        ),
      );
    } catch (error) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException
                  ? error.message
                  : '屏蔽标签未能保存，原有规则保持不变，请重试。',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _blockingTag = false);
    }
  }

  Widget _buildEmptyState() {
    final store = _blocklist;
    final loading = store == null || !store.loaded;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(title: const Text('作品详情')),
          body: SafeArea(
            child: Center(
              child: loading
                  ? const CircularProgressIndicator(semanticsLabel: '正在读取屏蔽规则')
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.filter_alt_outlined, size: 40),
                          const SizedBox(height: 12),
                          Text(
                            widget.posts.isEmpty ? '此列表没有作品' : '此列表中的作品都已被标签屏蔽',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          TagBlocklistStatus(
                            hiddenCount: widget.posts.length,
                            blocklist: store,
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyTag(String tag) async {
    try {
      await Clipboard.setData(ClipboardData(text: tag));
      _showMessage('已复制标签: $tag');
    } catch (_) {
      _showMessage('无法写入剪贴板，请稍后重试。');
    }
  }

  Future<void> _copyLink(String url, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      _showMessage('已复制$label');
    } catch (_) {
      _showMessage('无法写入剪贴板，请稍后重试。');
    }
  }

  Future<void> _sharePost(Post post) async {
    if (!mounted || !_posts.any((visible) => visible.id == post.id)) return;
    _video.pause();
    final intro = await _postIntro(post).timeout(
      const Duration(milliseconds: 1200),
      onTimeout: () => _fallbackPostIntro(post),
    );
    if (!mounted || !_posts.any((visible) => visible.id == post.id)) return;
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
      if (!mounted || !_posts.any((visible) => visible.id == post.id)) return;
      try {
        await Clipboard.setData(ClipboardData(text: text));
        _showMessage('系统分享不可用，已复制作品链接和简介。');
      } catch (_) {
        _showMessage('系统分享和剪贴板暂时不可用，请稍后重试。');
      }
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

    final tagList = tags.trim().split(RegExp(r'\s+'));

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
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(
                    80,
                    360,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onLongPress: () => _showTagMenu(context, tag),
                        child: Tooltip(
                          message: tag,
                          child: InputChip(
                            label: Text(
                              displayLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: () => Navigator.pop(
                              context,
                              SearchChip(label: displayLabel, queryValue: tag),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '标签操作 $tag',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: () => _showTagMenu(context, tag),
                    ),
                  ],
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
    _video.pause();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (menuContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(menuContext).height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  tag,
                  style: Theme.of(menuContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.search),
                  title: const Text('搜索此标签'),
                  onTap: () {
                    final navigator = Navigator.of(menuContext);
                    navigator.pop();
                    navigator.pop(tag);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('复制标签'),
                  onTap: () {
                    Navigator.pop(menuContext);
                    _copyTag(tag);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.favorite_border),
                  title: const Text('收藏标签'),
                  onTap: () {
                    Navigator.pop(menuContext);
                    _toggleFavoriteTag(tag);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.block),
                  title: const Text('屏蔽此标签'),
                  enabled: !_blockingTag,
                  onTap: () {
                    Navigator.pop(menuContext);
                    _blockTag(tag);
                  },
                ),
              ],
            ),
          ),
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
    final generation = _pagerGeneration;
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          PageView.builder(
            key: ValueKey(_pagerGeneration),
            controller: _pageController,
            itemCount: _posts.length,
            onPageChanged: (index) {
              if (generation == _pagerGeneration) _onPageChanged(index);
            },
            itemBuilder: (context, index) {
              final post = _posts[index];
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
                    onOpenFullScreen: () => _openFullScreen(post.id),
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
                                  onPressed: () {
                                    if (_currentPost?.id == post.id) {
                                      _loadMediaForIndex(_currentIndex);
                                    }
                                  },
                                  child: const Text('重试'),
                                ),
                              OutlinedButton.icon(
                                onPressed: () => _openPostExternally(post.id),
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
                              onPressed: () => _openFullScreen(post.id),
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
                  canInteract: () => mounted && _currentPost?.id == post.id,
                  child: media,
                );
              }
              return GestureDetector(
                onTap: source == null ? null : () => _openFullScreen(post.id),
                child: media,
              );
            },
          ),
          if (_posts.length > 1) ...[
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
                  onPressed: _currentIndex + 1 >= _posts.length
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
        TagBlocklistStatus(
          hiddenCount: widget.posts.length - _posts.length,
          blocklist: _blocklist,
        ),
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

  void _savePost(int postId) {
    if (!mounted) return;
    final post = _posts.where((post) => post.id == postId).firstOrNull;
    final source = post?.fileUrl ?? post?.largeFileUrl;
    if (source == null) return;
    _video.pause();
    saveMediaToGallery(context, source);
  }

  void _openPostExternally(int postId) {
    if (!mounted) return;
    final post = _posts.where((post) => post.id == postId).firstOrNull;
    final source = post?.fileUrl ?? post?.largeFileUrl;
    if (source == null) return;
    _video.pause();
    openMediaExternally(
      context,
      source,
      canInteract: () => mounted && _posts.any((post) => post.id == postId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentPostForTags = _currentPost;
    if (currentPostForTags == null) return _buildEmptyState();
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
                      : () => _savePost(currentPostForTags.id),
                ),
              IconButton(
                icon: Icon(
                  _isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: _isFavorite
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: _favoriteWritePending
                    ? null
                    : () => _toggleFavorite(currentPostForTags.id),
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
                    if (action == 'save') _savePost(currentPostForTags.id);
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
