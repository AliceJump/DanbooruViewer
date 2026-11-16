import 'package:danbooru_viewer/post.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ID-only legacy collection entries remain readable', () {
    final post = Post.fromJson({'id': 42});
    expect(post.id, 42);
    expect(post.rating, isEmpty);
    expect(post.tagString, isEmpty);
    expect(post.toJson()['id'], 42);
  });

  test(
    'wrong-type fields are not silently converted into a different record',
    () {
      expect(() => Post.fromJson({'id': '42'}), throwsA(isA<TypeError>()));
      expect(
        () => Post.fromJson({
          'id': 42,
          'tag_string': ['cat'],
        }),
        throwsA(isA<TypeError>()),
      );
    },
  );
}
