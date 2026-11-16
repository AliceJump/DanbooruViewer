import 'dart:convert';

import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
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

String _rules(List<String> tags) =>
    jsonEncode({'version': 1, 'enabled': true, 'tags': tags});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SharedPreferences.setMockInitialValues({}));

  for (final failure in PreferenceFailure.values) {
    test(
      'real preferences cache changes before a $failure platform write',
      () async {
        final backend = FailingPreferencesStore({'example': 'saved'});
        final preferences = await backend.install();
        backend.setFailures['example'] = failure;

        if (failure == PreferenceFailure.returnFalse) {
          expect(await preferences.setString('example', 'unsaved'), isFalse);
        } else {
          await expectLater(
            preferences.setString('example', 'unsaved'),
            throwsStateError,
          );
        }

        // This exercises the actual plugin cache, not a mock of its public API.
        expect(preferences.getString('example'), 'unsaved');
        expect(backend.persisted['example'], 'saved');
        await preferences.reload();
        expect(preferences.getString('example'), 'saved');
      },
    );

    test(
      'failed favorite write ($failure) preserves reads, backup and retry',
      () async {
        final original = jsonEncode([_post(1)]);
        final backend = FailingPreferencesStore({
          _fullKey: original,
          _idsKey: '[1]',
        });
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        backend.setFailures[_fullKey] = failure;

        await expectLater(manager.toggleFavorite(_post(2)), throwsStateError);

        expect(backend.persisted[_fullKey], original);
        expect(preferences.getString(_fullKey), original);
        expect(await manager.getFavoritePostsFull(), [_post(1)]);
        expect(await manager.getFavoritePostIds(), [1]);
        final backup = jsonDecode(await manager.exportBackupJson());
        expect(backup['values'][_fullKey], original);

        backend.setFailures.remove(_fullKey);
        // A retry must add the item, not undo an uncommitted cached toggle.
        expect(await manager.toggleFavorite(_post(2)), isTrue);
        expect(await manager.getFavoritePostIds(), [2, 1]);
        expect(jsonDecode(backend.persisted[_fullKey]! as String), [
          _post(2),
          _post(1),
        ]);
      },
    );

    test(
      'failed write and reload ($failure) block dirty favorite reads and writes',
      () async {
        final original = jsonEncode([_post(1)]);
        final backend = FailingPreferencesStore({
          _fullKey: original,
          _idsKey: '[1]',
        });
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        backend.setFailures[_fullKey] = failure;
        backend.failReads = true;

        await expectLater(manager.toggleFavorite(_post(2)), throwsStateError);
        expect(preferences.getString(_fullKey), isNot(original));
        expect(backend.persisted[_fullKey], original);
        final writesAfterFailure = backend.setCalls.length;

        await expectLater(manager.getFavoritePostsFull(), throwsStateError);
        await expectLater(manager.getFavoritePostIds(), throwsStateError);
        await expectLater(manager.exportBackupJson(), throwsStateError);
        await expectLater(manager.toggleFavorite(_post(3)), throwsStateError);
        expect(backend.setCalls, hasLength(writesAfterFailure));
        expect(backend.persisted[_fullKey], original);

        backend.failReads = false;
        backend.setFailures.remove(_fullKey);
        expect(await manager.getFavoritePostsFull(), [_post(1)]);
        expect(await manager.toggleFavorite(_post(2)), isTrue);
        expect(await manager.getFavoritePostIds(), [2, 1]);
      },
    );

    test(
      'legacy mirror failure ($failure) does not fail a committed toggle',
      () async {
        final backend = FailingPreferencesStore({
          _fullKey: jsonEncode([_post(1)]),
          _idsKey: '[1]',
        });
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        backend.setFailures[_idsKey] = failure;

        expect(await manager.toggleFavorite(_post(2)), isTrue);
        expect(jsonDecode(backend.persisted[_fullKey]! as String), [
          _post(2),
          _post(1),
        ]);
        expect(backend.persisted[_idsKey], '[1]');
        expect(await manager.getFavoritePostIds(), [2, 1]);

        await preferences.reload();
        final reopened = FavoritesManager.forTesting(preferences);
        expect(await reopened.isFavorite(2), isTrue);
        expect(await reopened.getFavoritePostIds(), [2, 1]);
        backend.setFailures.remove(_idsKey);
        // Only the next explicit toggle should remove the committed favorite.
        expect(await reopened.toggleFavorite(_post(2)), isFalse);
        expect(await reopened.getFavoritePostIds(), [1]);
        expect(jsonDecode(backend.persisted[_fullKey]! as String), [_post(1)]);
      },
    );

    test(
      'failed history remove ($failure) retains records and permits retry',
      () async {
        final original = jsonEncode([_post(1)]);
        final backend = FailingPreferencesStore({_historyKey: original});
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        backend.removeFailures[_historyKey] = failure;

        await expectLater(manager.clearBrowsingHistory(), throwsStateError);
        expect(backend.persisted[_historyKey], original);
        expect(preferences.getString(_historyKey), original);
        expect(await manager.getBrowsingHistory(), [_post(1)]);
        final backup = jsonDecode(await manager.exportBackupJson());
        expect(backup['values'][_historyKey], original);

        backend.removeFailures.remove(_historyKey);
        await manager.clearBrowsingHistory();
        expect(await manager.getBrowsingHistory(), isEmpty);
        expect(backend.persisted.containsKey(_historyKey), isFalse);
      },
    );

    test(
      'failed blocklist write ($failure) is not accepted by retryLoad',
      () async {
        final original = _rules(['cat']);
        final backend = FailingPreferencesStore({
          TagBlocklist.storageKey: original,
        });
        final preferences = await backend.install();
        final store = TagBlocklist(loadPreferences: () async => preferences);
        addTearDown(store.dispose);
        await store.initialize();
        backend.setFailures[TagBlocklist.storageKey] = failure;

        await expectLater(store.addTags(['dog']), throwsStateError);
        expect(store.tags, ['cat']);
        expect(backend.persisted[TagBlocklist.storageKey], original);
        await store.retryLoad();
        expect(store.loadError, isNull);
        expect(store.tags, ['cat']);
        expect(store.hides('dog'), isFalse);
        expect(await store.rawBackup(), original);

        backend.setFailures.remove(TagBlocklist.storageKey);
        expect(await store.addTags(['dog']), {'dog'});
        expect(store.tags, ['cat', 'dog']);
        final saved = jsonDecode(
          backend.persisted[TagBlocklist.storageKey]! as String,
        );
        expect(saved['tags'], ['cat', 'dog']);
      },
    );

    test(
      'failed blocklist write and reload ($failure) keep old rules authoritative',
      () async {
        final original = _rules(['cat']);
        final backend = FailingPreferencesStore({
          TagBlocklist.storageKey: original,
        });
        final preferences = await backend.install();
        final store = TagBlocklist(loadPreferences: () async => preferences);
        addTearDown(store.dispose);
        await store.initialize();
        backend.setFailures[TagBlocklist.storageKey] = failure;
        backend.failReads = true;

        await expectLater(store.addTags(['dog']), throwsStateError);
        expect(preferences.getString(TagBlocklist.storageKey), isNot(original));
        expect(backend.persisted[TagBlocklist.storageKey], original);
        expect(store.tags, ['cat']);
        expect(store.hides('cat'), isTrue);
        expect(store.hides('dog'), isFalse);
        expect(store.loadError, isNotNull);
        final writesAfterFailure = backend.setCalls.length;

        await store.retryLoad();
        expect(store.loadError, isNotNull);
        expect(store.tags, ['cat']);
        await expectLater(store.rawBackup(), throwsStateError);
        await expectLater(store.addTags(['bird']), throwsStateError);
        expect(backend.setCalls, hasLength(writesAfterFailure));

        // A second store must not accept the first one's poisoned plugin cache.
        final reopened = TagBlocklist(loadPreferences: () async => preferences);
        addTearDown(reopened.dispose);
        await reopened.initialize();
        expect(reopened.loadError, isNotNull);
        expect(reopened.tags, isEmpty);
        await expectLater(reopened.rawBackup(), throwsStateError);

        backend.failReads = false;
        backend.setFailures.remove(TagBlocklist.storageKey);
        await store.retryLoad();
        expect(store.loadError, isNull);
        expect(store.tags, ['cat']);
        expect(await store.rawBackup(), original);
        await reopened.retryLoad();
        expect(reopened.tags, ['cat']);
        expect(await store.addTags(['dog']), {'dog'});
        expect(store.tags, ['cat', 'dog']);
      },
    );

    test(
      'combined backup rejects another store\'s failed write cache ($failure)',
      () async {
        final original = _rules(['cat']);
        final backend = FailingPreferencesStore({
          TagBlocklist.storageKey: original,
        });
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        final store = TagBlocklist(loadPreferences: () async => preferences);
        addTearDown(store.dispose);
        await store.initialize();
        backend.setFailures[TagBlocklist.storageKey] = failure;
        backend.failReads = true;

        await expectLater(store.addTags(['dog']), throwsStateError);
        await expectLater(manager.exportBackupJson(), throwsStateError);
        expect(backend.persisted[TagBlocklist.storageKey], original);

        backend.failReads = false;
        final backup = jsonDecode(await manager.exportBackupJson());
        expect(backup['values'][TagBlocklist.storageKey], original);
      },
    );
  }
}
