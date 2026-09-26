import 'package:danbooru_viewer/media_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('video URLs are recognized with query parameters', () {
    expect(isVideoUrl('https://example.com/media/clip.mp4?token=abc'), isTrue);
    expect(isVideoUrl('https://example.com/media/clip.webm#preview'), isTrue);
    expect(isVideoUrl('https://example.com/media/clip.png?token=abc'), isFalse);
  });
}
