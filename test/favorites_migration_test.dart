import 'dart:convert';

import 'package:danbooru_viewer/completion_service.dart';
import 'package:danbooru_viewer/favorites_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_completion_service.dart';

void main() {
  late SharedPreferences preferences;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  testWidgets(
    'a failed metadata batch still migrates known and fallback categories',
    (tester) async {
      await preferences.setString(
        'favorite_tags',
        jsonEncode(['blue_hair', 'hatsune_miku', 'unknown_tag']),
      );
      // The local post adds enough unrelated tags to require a second batch.
      // Its failure must not discard metadata already received for favorites.
      await preferences.setString(
        'favorite_posts_full',
        jsonEncode([
          {
            'id': 1,
            'rating': 'g',
            'tag_string': List.generate(254, (i) => 'local_tag_$i').join(' '),
          },
        ]),
      );
      final service = FakeCompletionService(
        onLookup: (tags) async {
          if (!tags.contains('blue_hair')) {
            throw StateError('second metadata batch unavailable');
          }
          return {
            'blue_hair': const CompletionTagInfo(label: '蓝发', category: 0),
          };
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: FavoritesPage(
            completionService: service,
            completionCategoryByValue: const {'hatsune_miku': 4},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.lookups.map((batch) => batch.length), [256, 1]);
      final migrated =
          (jsonDecode(preferences.getString('favorite_tags_v2')!) as List)
              .cast<Map<String, dynamic>>();
      final categories = {
        for (final entry in migrated) entry['tag']: entry['category'],
      };
      expect(categories, {
        'blue_hair': 0,
        'hatsune_miku': 4,
        'unknown_tag': null,
      });

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 350));
      expect(service.disposeCalls, 0);
    },
  );
}
