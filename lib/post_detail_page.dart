import 'package:flutter/material.dart';
import 'main.dart';
import 'package:url_launcher/url_launcher.dart';

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
    final post = widget.posts[index];
    final highResUrl = post.fileUrl ?? post.largeFileUrl;

    if (highResUrl != null) {
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

    if (!_imageUrls.containsKey(index)) {
      _loadHighResImageForIndex(index);
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
                  final imageUrl = _imageUrls[index] ?? post.previewFileUrl!;

                  return Hero(
                    tag: 'post_${post.id}',
                    child: InteractiveViewer(
                      child: Image.network(
                        imageUrl,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Center(
                            child: CircularProgressIndicator(
                              value: loadingProgress.expectedTotalBytes != null
                                  ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                  : null,
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return const Icon(Icons.error);
                        },
                      ),
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
      floatingActionButton:
          (currentPostForTags.source != null && currentPostForTags.source!.isNotEmpty)
              ? FloatingActionButton(
                  onPressed: () => _launchUrl(currentPostForTags.source),
                  child: const Icon(Icons.link),
                )
              : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }
}
