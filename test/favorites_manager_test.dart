import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  SharedPreferences.setMockInitialValues({});
  final manager = FavoritesManager();

  setUp(() async {
    await manager.clearAllFavorites();
  });

  test(
    'concurrent favorite additions retain both posts and legacy IDs',
    () async {
      await Future.wait([
        manager.addFavorite({'id': 1}),
        manager.addFavorite({'id': 2}),
      ]);

      expect((await manager.getFavoritePostsFull()).map((post) => post['id']), [
        2,
        1,
      ]);
      expect(await manager.getFavoritePostIds(), [2, 1]);
    },
  );

  test('two rapid toggles return to the original favorite state', () async {
    final states = await Future.wait([
      manager.toggleFavorite({'id': 3}),
      manager.toggleFavorite({'id': 3}),
    ]);

    expect(states, [true, false]);
    expect(await manager.getFavoritePostsFull(), isEmpty);
  });

  test('tag additions and toggles do not overwrite one another', () async {
    await Future.wait([
      manager.addFavoriteTag('tag_a', category: 1),
      manager.addFavoriteTag('tag_b', category: 4),
    ]);
    expect((await manager.getFavoriteTags()).toSet(), {'tag_a', 'tag_b'});

    final states = await Future.wait([
      manager.toggleFavoriteTag('tag_a'),
      manager.toggleFavoriteTag('tag_a'),
    ]);
    expect(states, [false, true]);
    expect((await manager.getFavoriteTags()).toSet(), {'tag_a', 'tag_b'});
  });

  test(
    'history additions are preserved and clear wins when called last',
    () async {
      await Future.wait([
        manager.addBrowsingHistory({'id': 1}),
        manager.addBrowsingHistory({'id': 2}),
      ]);
      expect((await manager.getBrowsingHistory()).map((post) => post['id']), [
        2,
        1,
      ]);

      await Future.wait([
        manager.addBrowsingHistory({'id': 3}),
        manager.clearBrowsingHistory(),
      ]);
      expect(await manager.getBrowsingHistory(), isEmpty);
    },
  );

  test('clear all removes the full favorite records too', () async {
    await manager.addFavorite({'id': 5});
    await manager.clearAllFavorites();

    expect(await manager.getFavoritePostsFull(), isEmpty);
    expect(await manager.getFavoritePostIds(), isEmpty);
  });
}
