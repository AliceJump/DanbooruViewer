import 'dart:convert';

import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/storage/reliable_preferences.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/failing_preferences_store.dart';
import 'support/native_memory_preferences_store.dart';

const _fullKey = 'favorite_posts_full';
const _idsKey = 'favorite_posts';
Map<String, Object> _post(int id) => {
  'id': id,
  'rating': 'g',
  'tag_string': 'cat',
};
String _rules(List<String> tags) =>
    jsonEncode({'version': 1, 'enabled': true, 'tags': tags});

class _FailFirstSetStore extends NativeMemoryPreferencesStore {
  _FailFirstSetStore(super.initialValues);

  bool _failed = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (_failed) return super.setValue(valueType, key, value);
    _failed = true;
    final name = key.substring('flutter.'.length);
    failures[name] = PreferenceFailure.returnFalse;
    try {
      return await super.setValue(valueType, key, value);
    } finally {
      failures.remove(name);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test(
    'failed native favorite commit cannot reverse a retry or taint backup',
    () async {
      final original = jsonEncode([_post(1)]);
      final backend = NativeMemoryPreferencesStore({_fullKey: original});
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);
      backend.failures[_fullKey] = PreferenceFailure.returnFalse;
      await expectLater(manager.toggleFavorite(_post(2)), throwsStateError);
      await preferences.reload();
      expect(await manager.getFavoritePostIds(), [1]);
      final backup = jsonDecode(await manager.exportBackupJson());
      expect(backup['values'][_fullKey], original);
      expect(backend.persisted[_fullKey], original);
      backend.failures.clear();
      await manager.reload();
      expect(backend.persisted[_fullKey], original);
      expect(await manager.toggleFavorite(_post(2)), isTrue);
      expect(await manager.getFavoritePostIds(), [2, 1]);
      expect(jsonDecode(backend.persisted[_fullKey]! as String), [
        _post(2),
        _post(1),
      ]);
    },
  );

  test(
    'another store cannot commit a failed favorite through the native map',
    () async {
      final original = jsonEncode([_post(1)]);
      final backend = NativeMemoryPreferencesStore({
        _fullKey: original,
        TagBlocklist.storageKey: _rules(['cat']),
      });
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);
      final store = TagBlocklist(loadPreferences: () async => preferences);
      addTearDown(store.dispose);
      await store.initialize();
      backend.failures[_fullKey] = PreferenceFailure.returnFalse;
      await expectLater(manager.toggleFavorite(_post(2)), throwsStateError);
      await expectLater(store.addTags(['dog']), throwsStateError);
      expect(backend.attemptedWrites, isNot(contains(TagBlocklist.storageKey)));
      expect(backend.persisted[_fullKey], original);
      expect(store.tags, ['cat']);
    },
  );

  test(
    'blocklist retryLoad cannot accept failed native-memory rules',
    () async {
      final original = _rules(['cat']);
      final backend = NativeMemoryPreferencesStore({
        TagBlocklist.storageKey: original,
      });
      final preferences = await backend.install();
      final store = TagBlocklist(loadPreferences: () async => preferences);
      addTearDown(store.dispose);
      await store.initialize();
      backend.failures[TagBlocklist.storageKey] = PreferenceFailure.returnFalse;
      await expectLater(store.addTags(['dog']), throwsStateError);
      await store.retryLoad();
      expect(store.tags, ['cat']);
      expect(store.loadError, isNotNull);
      expect(await store.rawBackup(), original);
      backend.failures.clear();
      await store.retryLoad();
      expect(store.loadError, isNull);
      expect(store.tags, ['cat']);
      await store.addTags(['dog']);
      expect(
        jsonDecode(
          backend.persisted[TagBlocklist.storageKey]! as String,
        )['tags'],
        ['cat', 'dog'],
      );
    },
  );

  for (final existed in [false, true]) {
    test(
      'a confirmed rollback restores the old value or absence: $existed',
      () async {
        final original = jsonEncode([_post(1)]);
        final backend = _FailFirstSetStore({if (existed) _fullKey: original});
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        await expectLater(
          manager.toggleFavorite(_post(2)),
          throwsA(
            isA<PreferencesWriteException>().having(
              (error) => error.recoveryRequired,
              'recoveryRequired',
              isFalse,
            ),
          ),
        );
        expect(
          ReliablePreferences.forInstance(preferences).recoveryRequired,
          isFalse,
        );
        expect(backend.nativeMemory[_fullKey], existed ? original : null);
        expect(backend.persisted[_fullKey], existed ? original : null);
        expect(await manager.getFavoritePostIds(), existed ? [1] : <int>[]);
        expect(await manager.toggleFavorite(_post(2)), isTrue);
        expect(await manager.getFavoritePostIds(), existed ? [2, 1] : [2]);
      },
    );
  }

  for (final failure in <PreferenceFailure?>[
    null,
    PreferenceFailure.returnFalse,
  ]) {
    test(
      'new stores and a combined backup await the pending native commit: $failure',
      () async {
        final original = jsonEncode([_post(1)]);
        final backend = NativeMemoryPreferencesStore({
          _fullKey: original,
          TagBlocklist.storageKey: _rules(['cat']),
        })..heldKey = _fullKey;
        addTearDown(backend.release);
        if (failure != null) backend.failures[_fullKey] = failure;
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        final write = manager.toggleFavorite(_post(2));
        final checkedWrite = expectLater(
          write,
          failure == null ? completion(isTrue) : throwsStateError,
        );
        await backend.started.future;
        expect(backend.nativeMemory[_fullKey], isNot(original));
        expect(backend.persisted[_fullKey], original);

        final reopened = FavoritesManager.forTesting(preferences);
        final blocklist = TagBlocklist(
          loadPreferences: () async => preferences,
        );
        addTearDown(blocklist.dispose);
        var backupCompleted = false;
        var loaded = false;
        final backup = reopened.exportBackupJson().then((value) {
          backupCompleted = true;
          return value;
        });
        final load = blocklist.initialize().then((_) => loaded = true);
        await Future<void>.delayed(Duration.zero);
        expect(backupCompleted, isFalse);
        expect(loaded, isFalse);

        backend.release();
        await checkedWrite;
        await load;
        final decoded = jsonDecode(await backup);
        expect(
          jsonDecode(decoded['values'][_fullKey] as String),
          failure == null ? [_post(2), _post(1)] : [_post(1)],
        );
        expect(blocklist.tags, ['cat']);
        expect(blocklist.loadError, failure == null ? isNull : isNotNull);
        expect(decoded['recovery_keys'], failure == null ? isNull : [_fullKey]);
      },
    );
  }

  for (final originalIds in <Object>[
    '[1]',
    <Object?>['1'],
  ]) {
    test(
      'a failed ID mirror preserves the committed full record and its original type: ${originalIds.runtimeType}',
      () async {
        final backend = NativeMemoryPreferencesStore({
          _fullKey: jsonEncode([_post(1)]),
          _idsKey: originalIds,
        });
        final preferences = await backend.install();
        final manager = FavoritesManager.forTesting(preferences);
        backend.failures[_idsKey] = PreferenceFailure.returnFalse;

        expect(await manager.toggleFavorite(_post(2)), isTrue);
        expect(await manager.getFavoritePostIds(), [2, 1]);
        final backup = jsonDecode(await manager.exportBackupJson());
        expect(jsonDecode(backup['values'][_fullKey] as String), [
          _post(2),
          _post(1),
        ]);
        expect(backup['values'][_idsKey], originalIds);
        expect(backup['recovery_keys'], [_idsKey]);
        expect(jsonDecode(backend.persisted[_fullKey]! as String), [
          _post(2),
          _post(1),
        ]);

        backend.failures.clear();
        await manager.reload();
        expect(backend.persisted[_idsKey], originalIds);
        expect(
          ReliablePreferences.forInstance(preferences).recoveryRequired,
          isFalse,
        );
        expect(
          await FavoritesManager.forTesting(
            preferences,
          ).toggleFavorite(_post(2)),
          isFalse,
        );
        expect(await manager.getFavoritePostIds(), [1]);
      },
    );
  }

  test(
    'wrong-type lists remain exportable and cannot be overwritten without a recovery value',
    () async {
      final backend = NativeMemoryPreferencesStore({
        _fullKey: jsonEncode([_post(1)]),
        _idsKey: <Object?>[1, 'bad'],
        'unrelated': <Object?>[null, 9],
      });
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);
      final storage = ReliablePreferences.forInstance(preferences);
      expect(await manager.toggleFavorite(_post(2)), isTrue);
      expect(await manager.getFavoritePostIds(), [2, 1]);
      expect(backend.attemptedWrites, [_fullKey]);
      final backup = jsonDecode(await manager.exportBackupJson());
      expect(backup['values'][_idsKey], [1, 'bad']);
      expect((await storage.readAll())['unrelated'], [null, 9]);
      await expectLater(storage.setString(_idsKey, '[2,1]'), throwsStateError);
      await expectLater(storage.remove(_idsKey), throwsStateError);
      expect(backend.attemptedWrites, [_fullKey]);
      expect(backend.persisted[_idsKey], [1, 'bad']);
      expect(storage.recoveryRequired, isFalse);
    },
  );

  test(
    'explicit reload can read externally repaired data without refreshing ordinary reads',
    () async {
      final backend = NativeMemoryPreferencesStore({_fullKey: '{broken'});
      final preferences = await backend.install();
      final manager = FavoritesManager.forTesting(preferences);
      final invalid = throwsA(isA<FavoritesDataException>());
      await expectLater(manager.getFavoritePostsFull(), invalid);
      // Model an explicit external repair, outside normal application writers.
      await preferences.setString(_fullKey, jsonEncode([_post(1)]));
      await expectLater(manager.getFavoritePostsFull(), invalid);
      await manager.reload();
      expect(await manager.getFavoritePostsFull(), [_post(1)]);
      expect(await manager.toggleFavorite(_post(2)), isTrue);
      expect(await manager.getFavoritePostIds(), [2, 1]);
    },
  );
}
