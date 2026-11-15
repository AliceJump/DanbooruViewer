import 'dart:async';

import 'package:danbooru_viewer/completion_service.dart';
import 'package:danbooru_viewer/main.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_completion_service.dart';

void main() {
  SharedPreferences.setMockInitialValues({});

  testWidgets(
    'detail loads labels only for the current post and on page changes',
    (tester) async {
      final firstLookup = Completer<Map<String, CompletionTagInfo>>();
      final service = FakeCompletionService(
        onLookup: (tags) async {
          if (tags.contains('blue_hair')) return firstLookup.future;
          return {
            'red_hair': const CompletionTagInfo(label: '红发', category: 0),
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: [
              Post(
                id: 1,
                rating: 'g',
                tagString: 'blue_hair',
                tagStringGeneral: 'blue_hair',
              ),
              Post(
                id: 2,
                rating: 'g',
                tagString: 'red_hair',
                tagStringGeneral: 'red_hair',
              ),
            ],
            initialIndex: 0,
            completionDisplayByValue: const {},
            completionService: service,
          ),
        ),
      );
      await tester.pump();
      expect(service.lookups, [
        ['blue_hair'],
      ]);
      expect(find.widgetWithText(InputChip, 'blue_hair'), findsOneWidget);

      firstLookup.complete({
        'blue_hair': const CompletionTagInfo(label: '蓝发', category: 0),
      });
      await tester.pump();
      await tester.pump();
      expect(find.widgetWithText(InputChip, '蓝发'), findsOneWidget);

      final pagerRect = tester.getRect(find.byType(PageView));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(PageView),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(pagerRect.width);
      await tester.pump();
      await tester.pump();
      expect(service.lookups, [
        ['blue_hair'],
        ['red_hair'],
      ]);
      expect(find.widgetWithText(InputChip, '红发'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox());
      expect(service.disposeCalls, 0);
    },
  );
}
