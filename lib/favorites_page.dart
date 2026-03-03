import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'favorites_manager.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _favoritesManager = FavoritesManager();

  List<int> _favoritePosts = [];
  List<String> _favoriteTags = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadFavorites();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    setState(() {
      _isLoading = true;
    });

    final posts = await _favoritesManager.getFavoritePosts();
    final tags = await _favoritesManager.getFavoriteTags();

    if (mounted) {
      setState(() {
        _favoritePosts = posts;
        _favoriteTags = tags;
        _isLoading = false;
      });
    }
  }

  Future<void> _removePost(int postId) async {
    await _favoritesManager.removeFavorite(postId);
    await _loadFavorites();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消收藏')),
      );
    }
  }

  Future<void> _removeTag(String tag) async {
    await _favoritesManager.removeFavoriteTag(tag);
    await _loadFavorites();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消收藏标签')),
      );
    }
  }

  void _copyTag(String tag) {
    Clipboard.setData(ClipboardData(text: tag));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制标签: $tag')),
    );
  }

  void _searchTag(String tag) {
    Navigator.pop(context, tag);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: const Icon(Icons.image),
              text: '图片 (${_favoritePosts.length})',
            ),
            Tab(
              icon: const Icon(Icons.label),
              text: '标签 (${_favoriteTags.length})',
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFavorites,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildPostsTab(),
                _buildTagsTab(),
              ],
            ),
    );
  }

  Widget _buildPostsTab() {
    if (_favoritePosts.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_border, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              '还没有收藏的图片',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              '在图片详情页点击收藏按钮来添加收藏',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _favoritePosts.length,
      itemBuilder: (context, index) {
        final postId = _favoritePosts[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Text('${index + 1}'),
            ),
            title: Text('Post ID: $postId'),
            subtitle: Text('收藏时间: ${DateTime.now().toString().split('.')[0]}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () {
                    // TODO: 跳转到图片详情页
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('跳转功能开发中')),
                    );
                  },
                  tooltip: '查看',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _removePost(postId),
                  tooltip: '取消收藏',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTagsTab() {
    if (_favoriteTags.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.label_off, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              '还没有收藏的标签',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              '在标签列表中长按标签来收藏',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _favoriteTags.length,
      itemBuilder: (context, index) {
        final tag = _favoriteTags[index];
        return Card(
          child: InkWell(
            onTap: () => _searchTag(tag),
            onLongPress: () => _showTagOptions(tag),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  const Icon(Icons.label, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tag,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showTagOptions(String tag) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索此标签'),
              onTap: () {
                Navigator.pop(context);
                _searchTag(tag);
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
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('取消收藏', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _removeTag(tag);
              },
            ),
          ],
        ),
      ),
    );
  }
}
