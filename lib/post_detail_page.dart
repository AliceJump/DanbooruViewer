import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'full_screen_image_page.dart';
import 'main.dart';

class PostDetailPage extends StatefulWidget {
  final List<Post> posts;
  final int initialIndex;

  const PostDetailPage(
      {super.key, required this.posts, required this.initialIndex});

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, String> _imageUrls = {};
  bool _didChangeDependenciesRun = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didChangeDependenciesRun) {
      _loadHighResImageForIndex(_currentIndex);
      _didChangeDependenciesRun = true;
    }
  }

  void _loadHighResImageForIndex(int index) {
    if (index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    final highResUrl = post.fileUrl ?? post.largeFileUrl;

    if (highResUrl != null && _imageUrls[index] == null) {
      precacheImage(NetworkImage(highResUrl), context).then((_) {
        if (mounted) {
          setState(() {
            _imageUrls[index] = highResUrl;
          });
        }
      });
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _loadHighResImageForIndex(index);
  }

  Future<void> _saveImage(BuildContext context, String? imageUrl) async {
    if (imageUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可保存的图片')),
      );
      return;
    }

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final status = await Gal.requestAccess();
        if (!status) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要存储权限来保存图片')),
          );
          return;
        }
      }
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/${imageUrl.split('/').last}';
      await Dio().download(imageUrl, path);
      await Gal.putImage(path, album: 'danbooru_viewer');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图片已保存到相册')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
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
            child: Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
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
    if (urlString != null &&
        urlString.isNotEmpty &&
        await canLaunchUrl(Uri.parse(urlString))) {
      await launchUrl(Uri.parse(urlString),
          mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('无法打开链接: $urlString'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPostForTags = widget.posts[_currentIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text('Post #${currentPostForTags.id}'),
      ),
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
                  final highResUrlForDetailPage = _imageUrls[index];
                  final definitiveHighResUrl =
                      post.fileUrl ?? post.largeFileUrl;
                  final heroTag = 'post_${post.id}';

                  if (previewUrl == null) {
                    return const Center(child: Icon(Icons.broken_image));
                  }

                  return GestureDetector(
                    onTap: () {
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
                    },
                    onLongPress: () => _saveImage(
                        context, definitiveHighResUrl ?? previewUrl),
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
                        AnimatedOpacity(
                          opacity: highResUrlForDetailPage != null &&
                                  highResUrlForDetailPage != previewUrl
                              ? 1.0
                              : 0.0,
                          duration: const Duration(milliseconds: 300),
                          child: highResUrlForDetailPage != null
                              ? Image.network(highResUrlForDetailPage,
                                  fit: BoxFit.contain)
                              : const SizedBox.shrink(),
                        ),
                        if (highResUrlForDetailPage == null &&
                            (post.fileUrl != null ||
                                post.largeFileUrl != null))
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
                  '作者', currentPostForTags.tag_string_artist, context),
              _buildTagSection(
                  '版权', currentPostForTags.tag_string_copyright, context),
              _buildTagSection(
                  '角色', currentPostForTags.tag_string_character, context),
              _buildTagSection(
                  '普通', currentPostForTags.tag_string_general, context),
            ]),
          )
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
