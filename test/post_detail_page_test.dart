import 'package:danbooru_viewer/main.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('keeps the current post when orientation changes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => tester.view.resetPhysicalSize());

    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpWidget(
      MaterialApp(
        home: PostDetailPage(
          posts: [
            Post(id: 1, rating: 'g', tagString: ''),
            Post(id: 2, rating: 'g', tagString: ''),
            Post(id: 3, rating: 'g', tagString: ''),
          ],
          initialIndex: 0,
          completionDisplayByValue: const {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pagerRect = tester.getRect(find.byType(PageView));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Scrollable),
      ),
    );
    scrollable.position.jumpTo(pagerRect.width);
    await tester.pumpAndSettle();
    expect(find.text('Post #2'), findsOneWidget);

    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    expect(find.text('Post #2'), findsOneWidget);

    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    expect(find.text('Post #2'), findsOneWidget);
  });
}
