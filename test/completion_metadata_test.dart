import 'dart:async';
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
  setUp(() async => preferences.clear());

  testWidgets(
    'favorites load metadata, migrate category and filter both tag labels',
    (tester) async {
      await preferences.setString(
        'favorite_tags',
        jsonEncode(['hatsune_miku']),
      );
      final lookup = Completer<Map<String, CompletionTagInfo>>();
      final service = FakeCompletionService(onLookup: (_) => lookup.future);
      await tester.pumpWidget(
        MaterialApp(home: FavoritesPage(completionService: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('标签 (1)'));
      await tester.pumpAndSettle();
      expect(service.lookups, [
        ['hatsune_miku'],
      ]);
      expect(find.text('hatsune_miku'), findsWidgets);
      final pendingEntries =
          jsonDecode(preferences.getString('favorite_tags_v2')!) as List;
      expect((pendingEntries.single as Map)['category'], isNull);

      lookup.complete({
        'hatsune_miku': const CompletionTagInfo(label: '初音未来', category: 4),
      });
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('初音未来'), findsWidgets);
      final migrated =
          jsonDecode(preferences.getString('favorite_tags_v2')!) as List;
      expect((migrated.single as Map)['category'], 4);

      final filter = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '筛选标签...',
      );
      await tester.enterText(filter, '初音');
      await tester.pump();
      expect(find.text('初音未来'), findsOneWidget);
      await tester.enterText(filter, 'MIKU');
      await tester.pump();
      expect(find.text('初音未来'), findsOneWidget);
      await tester.enterText(filter, 'missing');
      await tester.pump();
      expect(find.text('初音未来'), findsNothing);
      expect(find.text('没有匹配的收藏标签'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox());
      expect(service.disposeCalls, 0);
    },
  );
}
