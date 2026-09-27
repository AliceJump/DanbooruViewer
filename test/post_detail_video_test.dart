import 'dart:async';

import 'package:danbooru_viewer/main.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class DelayedVideoController extends VideoPlayerController {
  DelayedVideoController()
    : super.networkUrl(Uri.parse('https://example.test/video.mp4'));

  final initialized = Completer<void>();
  int disposeCalls = 0;

  @override
  Future<void> initialize() => initialized.future;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }
}

void main() {
  testWidgets('revisiting a loading video does not create another controller', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = DelayedVideoController();
    var created = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PostDetailPage(
          posts: [
            Post(
              id: 1,
              rating: 'g',
              tagString: '',
              fileUrl: 'https://example.test/video.mp4',
            ),
            Post(id: 2, rating: 'g', tagString: ''),
          ],
          initialIndex: 0,
          completionDisplayByValue: const {},
          videoControllerFactory: (_) {
            created++;
            return controller;
          },
        ),
      ),
    );
    expect(created, 1);

    final pageWidth = tester.getSize(find.byType(PageView)).width;
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Scrollable),
      ),
    );
    scrollable.position.jumpTo(pageWidth);
    await tester.pump();
    scrollable.position.jumpTo(0);
    await tester.pump();
    expect(created, 1);

    await tester.pumpWidget(const SizedBox());
    controller.initialized.complete();
    await tester.pump();
    expect(controller.disposeCalls, 1);
    await tester.pump(const Duration(milliseconds: 300));
  });
}
