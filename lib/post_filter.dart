import 'post.dart';
import 'tag_blocklist.dart';

/// Older saved posts may contain category tags without the aggregate field.
String postTagsForBlocking(Post post) => [
  post.tagString,
  post.tagStringGeneral,
  post.tagStringArtist,
  post.tagStringCharacter,
  post.tagStringCopyright,
  post.tagStringMeta,
].whereType<String>().join(' ');

/// Keep the selected ID when possible. If it becomes hidden, choose the next
/// visible post in the original order, then the closest previous post.
({List<Post> posts, int index}) filterPostList(
  List<Post> rawPosts,
  TagBlocklist blocklist, {
  int? selectedPostId,
  int initialIndex = 0,
}) {
  if (!blocklist.loaded) return (posts: const <Post>[], index: 0);
  final visible = List<Post>.unmodifiable(
    rawPosts.where((post) => !blocklist.hides(postTagsForBlocking(post))),
  );
  if (visible.isEmpty) return (posts: visible, index: 0);
  final retained = visible.indexWhere((post) => post.id == selectedPostId);
  if (retained >= 0) return (posts: visible, index: retained);
  final rawIndex = rawPosts.indexWhere((post) => post.id == selectedPostId);
  final anchor = rawIndex >= 0
      ? rawIndex
      : initialIndex.clamp(0, rawPosts.length - 1);
  final visibleIds = visible.map((post) => post.id).toSet();
  for (var index = anchor; index < rawPosts.length; index++) {
    final candidate = rawPosts[index];
    if (visibleIds.contains(candidate.id)) {
      return (
        posts: visible,
        index: visible.indexWhere((post) => post.id == candidate.id),
      );
    }
  }
  return (posts: visible, index: visible.length - 1);
}
