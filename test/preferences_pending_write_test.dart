import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/failing_preferences_store.dart';

const _fullKey = 'favorite_posts_full';
const _idsKey = 'favorite_posts';
const _historyKey = 'browsing_history_posts';

Map<String, Object> _post(int id) => {
  'id': id,
  'rating': 'g',
  'tag_string': 'cat',
};

class _PendingPreferencesStore extends FailingPreferencesStore {
  _PendingPreferencesStore(super.initialValues);

  final started = Completer<void>();
  final _release = Completer<void>();
  String? heldSetKey;
  String? heldRemoveKey;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<void> _hold() async {
    if (!started.isCompleted) started.complete();
    await _release.future;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.$heldSetKey') await _hold();
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.$heldRemoveKey') await _hold();
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  for (final failure in <PreferenceFailure?>[
    null,
    ...PreferenceFailure.values,
  ]) {
    final outcome = failure?.name ?? 'success';

    test('favorite reads wait for a pending platform write: $outcome', () async {
      final original = jsonEncode([_post(1)]);
      final backend = _PendingPreferencesStore({
        _fullKey: original,
        _idsKey: '[1]',
      })..heldSetKey = _fullKey;
      if (failure != null) backend.setFailures[_fullKey] = failure;
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);

      final write = manager.toggleFavorite(_post(2));
      final checkedWrite = expectLater(
        write,
        failure == null ? completion(isTrue) : throwsStateError,
      );
      await backend.started.future;
      expect(backend.persisted[_fullKey], original);
      // The real plugin has changed its cache but the platform has not replied.
      expect(preferences.getString(_fullKey), isNot(original));

      var fullReturned = false;
      var idsReturned = false;
      var favoriteReturned = false;
      final full = manager.getFavoritePostsFull().then((value) {
        fullReturned = true;
        return value;
      });
      final ids = manager.getFavoritePostIds().then((value) {
        idsReturned = true;
        return value;
      });
      final favorite = manager.isFavorite(2).then((value) {
        favoriteReturned = true;
        return value;
      });
      try {
        await Future<void>.delayed(Duration.zero);
        expect(fullReturned, isFalse);
        expect(idsReturned, isFalse);
        expect(favoriteReturned, isFalse);
      } finally {
        backend.release();
        await checkedWrite;
      }

      final expectedIds = failure == null ? [2, 1] : [1];
      expect((await full).map((post) => post['id']), expectedIds);
      expect(await ids, expectedIds);
      expect(await favorite, failure == null);
    });

    test('history reads wait for a pending append: $outcome', () async {
      final original = jsonEncode([_post(1)]);
      final backend = _PendingPreferencesStore({_historyKey: original})
        ..heldSetKey = _historyKey;
      if (failure != null) backend.setFailures[_historyKey] = failure;
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);

      final write = manager.addBrowsingHistory(_post(2));
      final checkedWrite = expectLater(
        write,
        failure == null ? completes : throwsStateError,
      );
      await backend.started.future;
      expect(preferences.getString(_historyKey), isNot(original));
      expect(backend.persisted[_historyKey], original);
      var returned = false;
      final history = manager.getBrowsingHistory().then((value) {
        returned = true;
        return value;
      });
      try {
        await Future<void>.delayed(Duration.zero);
        expect(returned, isFalse);
      } finally {
        backend.release();
        await checkedWrite;
      }
      expect(
        (await history).map((post) => post['id']),
        failure == null ? [2, 1] : [1],
      );
    });

    test('history reads wait for a pending clear: $outcome', () async {
      final original = jsonEncode([_post(1)]);
      final backend = _PendingPreferencesStore({_historyKey: original})
        ..heldRemoveKey = _historyKey;
      if (failure != null) backend.removeFailures[_historyKey] = failure;
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);

      final write = manager.clearBrowsingHistory();
      final checkedWrite = expectLater(
        write,
        failure == null ? completes : throwsStateError,
      );
      await backend.started.future;
      expect(preferences.containsKey(_historyKey), isFalse);
      expect(backend.persisted[_historyKey], original);
      var returned = false;
      final history = manager.getBrowsingHistory().then((value) {
        returned = true;
        return value;
      });
      try {
        await Future<void>.delayed(Duration.zero);
        expect(returned, isFalse);
      } finally {
        backend.release();
        await checkedWrite;
      }
      expect(
        (await history).map((post) => post['id']),
        failure == null ? isEmpty : [1],
      );
    });
  }

  test(
    'an unrelated reload during a pending write cannot hide its later commit',
    () async {
      final original = jsonEncode([_post(1)]);
      final backend = _PendingPreferencesStore({
        _fullKey: original,
        _idsKey: '[1]',
      })..heldSetKey = _fullKey;
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);
      final write = manager.toggleFavorite(_post(2));
      await backend.started.future;

      // A backup/settings reader shares the plugin singleton and can reload its
      // whole cache while this operation still awaits the platform response.
      await preferences.reload();
      expect(preferences.getString(_fullKey), original);
      backend.release();
      expect(await write, isTrue);
      expect(jsonDecode(backend.persisted[_fullKey]! as String), [
        _post(2),
        _post(1),
      ]);
      expect(await manager.getFavoritePostIds(), [2, 1]);
      expect(await manager.isFavorite(2), isTrue);
      await manager.addFavorite(_post(3));
      expect(await manager.getFavoritePostIds(), [3, 2, 1]);
    },
  );
}
