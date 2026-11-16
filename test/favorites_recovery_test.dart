import 'dart:convert';

import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(FavoritesManager, SharedPreferences)> fixture(
    Map<String, Object> data,
  ) async {
    SharedPreferences.setMockInitialValues(data);
    final preferences = await SharedPreferences.getInstance();
    return (FavoritesManager.forTesting(preferences), preferences);
  }

  test(
    'malformed favorites are preserved through failed reads and mutations',
    () async {
      const raw = '[{"id":42';
      final (manager, preferences) = await fixture({
        'favorite_posts_full': raw,
      });
      await expectLater(
        manager.getFavoritePostsFull(),
        throwsA(isA<FavoritesDataException>()),
      );
      await expectLater(
        manager.addFavorite({'id': 3}),
        throwsA(isA<FavoritesDataException>()),
      );
      expect(preferences.getString('favorite_posts_full'), raw);
      final backup = jsonDecode(await manager.exportBackupJson());
      expect(backup['values']['favorite_posts_full'], raw);
    },
  );

  test(
    'one invalid post rejects the whole collection instead of deleting it',
    () async {
      final raw = jsonEncode([
        {'id': 42, 'tag_string': 'cat'},
        {'id': 'broken'},
      ]);
      final (manager, preferences) = await fixture({
        'browsing_history_posts': raw,
      });
      await expectLater(
        manager.getBrowsingHistory(),
        throwsA(isA<FavoritesDataException>()),
      );
      await expectLater(
        manager.addBrowsingHistory({'id': 9}),
        throwsA(isA<FavoritesDataException>()),
      );
      expect(preferences.getString('browsing_history_posts'), raw);
    },
  );

  test('invalid legacy tags are not silently filtered and migrated', () async {
    final raw = jsonEncode(['cat', 42]);
    final (manager, preferences) = await fixture({'favorite_tags': raw});
    await expectLater(
      manager.getFavoriteTagEntries(),
      throwsA(isA<FavoritesDataException>()),
    );
    expect(preferences.getString('favorite_tags'), raw);
    expect(preferences.containsKey('favorite_tags_v2'), isFalse);
  });

  test(
    'legacy IDs remain authoritative until their details are recovered',
    () async {
      const raw = '[1,2]';
      final (manager, preferences) = await fixture({'favorite_posts': raw});
      expect(await manager.getFavoritePostIds(), [1, 2]);
      expect(await manager.isFavorite(1), isTrue);
      expect(await manager.isFavorite(3), isFalse);
      final recovery = throwsA(isA<LegacyFavoritesRecoveryException>());
      await expectLater(manager.getFavoritePostsFull(), recovery);
      await expectLater(manager.addFavorite({'id': 3}), recovery);
      await expectLater(manager.removeFavorite(1), recovery);
      await expectLater(manager.toggleFavorite({'id': 2}), recovery);
      expect(preferences.containsKey('favorite_posts_full'), isFalse);
      expect(preferences.getString('favorite_posts'), raw);
      final backup = jsonDecode(await manager.exportBackupJson());
      expect(backup['values'], {'favorite_posts': raw});
    },
  );

  for (final raw in <Object>['{broken', '{"id":1}', '[1,"bad"]', 42]) {
    test(
      'damaged legacy IDs block reads and mutations without overwriting: $raw',
      () async {
        final (manager, preferences) = await fixture({'favorite_posts': raw});
        final failure = throwsA(isA<FavoritesDataException>());
        await expectLater(manager.getFavoritePostsFull(), failure);
        await expectLater(manager.getFavoritePostIds(), failure);
        await expectLater(manager.isFavorite(1), failure);
        await expectLater(manager.addFavorite({'id': 3}), failure);
        await expectLater(manager.removeFavorite(1), failure);
        await expectLater(manager.toggleFavorite({'id': 2}), failure);
        expect(preferences.containsKey('favorite_posts_full'), isFalse);
        expect(preferences.get('favorite_posts'), raw);
        final backup = jsonDecode(await manager.exportBackupJson());
        expect(backup['values'], {'favorite_posts': raw});
      },
    );
  }

  test(
    'an empty legacy list allows the first full favorite to be saved',
    () async {
      final (manager, preferences) = await fixture({'favorite_posts': '[]'});
      expect(await manager.getFavoritePostsFull(), isEmpty);
      expect(
        await manager.toggleFavorite({'id': 3, 'tag_string': 'cat'}),
        isTrue,
      );
      expect(await manager.getFavoritePostIds(), [3]);
      expect(jsonDecode(preferences.getString('favorite_posts_full')!), [
        {'id': 3, 'tag_string': 'cat'},
      ]);
    },
  );

  test(
    'backup includes original wrong-type preferences without parsing them',
    () async {
      final (manager, _) = await fixture({
        'favorite_posts_full': 42,
        'tag_blocklist_v1': '{invalid',
        'network_settings_v1': 'private config',
        'post_commentary_42': 'cached commentary',
      });
      await expectLater(
        manager.getFavoritePostsFull(),
        throwsA(isA<FavoritesDataException>()),
      );
      final backup = jsonDecode(await manager.exportBackupJson());
      expect(backup['values'], {
        'favorite_posts_full': 42,
        'tag_blocklist_v1': '{invalid',
      });
    },
  );
}
