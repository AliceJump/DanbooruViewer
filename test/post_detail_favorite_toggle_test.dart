import 'dart:async';

import 'package:danbooru_viewer/main.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('favorite toggle wins over an older status lookup', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final status = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: PostDetailPage(
          posts: [Post(id: 3, rating: 'g', tagString: '')],
          initialIndex: 0,
          completionDisplayByValue: const {},
          isFavoriteLookup: (_) => status.future,
        ),
      ),
    );

    await tester.tap(find.byTooltip('收藏'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    status.complete(false);
    await tester.pump();
    expect(find.byTooltip('取消收藏'), findsOneWidget);
  });
}
