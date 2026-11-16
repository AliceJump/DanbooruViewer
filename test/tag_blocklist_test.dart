import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/failing_preferences_store.dart';

class _DelayedReadsStore extends FailingPreferencesStore {
  bool holdReads = false;
  final pendingReads = <Completer<void>>[];

  @override
  Future<Map<String, Object>> getAll() async {
    final snapshot = await super.getAll();
    if (holdReads) {
      final gate = Completer<void>();
      pendingReads.add(gate);
      await gate.future;
    }
    return snapshot;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<TagBlocklist> fresh([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    final preferences = await SharedPreferences.getInstance();
    final store = TagBlocklist(loadPreferences: () async => preferences);
    await store.initialize();
    addTearDown(store.dispose);
    return store;
  }

  test(
    'matches complete canonical tags with OR semantics, not substrings',
    () async {
      final store = await fresh();
      await store.addTags([' Cat ', 'BLUE_HAIR', 'cat']);
      expect(store.tags, ['blue_hair', 'cat']);
      expect(store.hides('landscape cat_ears'), isFalse);
      expect(store.hides('landscape cat'), isTrue);
      expect(store.hides('blue_hair solo'), isTrue);
      expect(store.hides('bobcat blue_hair_ornament'), isFalse);
      expect(store.matchingTags('CAT blue_hair cat'), ['cat', 'blue_hair']);
    },
  );

  test('rules and enabled state persist, temporary reveal does not', () async {
    final store = await fresh();
    await store.addTags(['cat']);
    store.setTemporarilyShow(true);
    expect(store.hides('cat'), isFalse);
    final reloaded = TagBlocklist();
    addTearDown(reloaded.dispose);
    await reloaded.initialize();
    expect(reloaded.hides('cat'), isTrue);
    await reloaded.setEnabled(false);
    final disabled = TagBlocklist();
    addTearDown(disabled.dispose);
    await disabled.initialize();
    expect(disabled.enabled, isFalse);
    expect(disabled.tags, ['cat']);
    expect(disabled.matches('cat'), isTrue);
    expect(disabled.hides('cat'), isFalse);
  });

  test(
    'concurrent additions and removals preserve independent changes',
    () async {
      final store = await fresh();
      await Future.wait([
        store.addTags(['cat']),
        store.addTags(['dog']),
        store.removeTags(['cat']),
        store.addTags(['bird']),
      ]);
      expect(store.tags, ['bird', 'dog']);
      final saved = jsonDecode(await store.rawBackup());
      expect(saved['tags'], ['bird', 'dog']);
    },
  );

  test(
    'invalid rules reject the whole update without losing saved rules',
    () async {
      final store = await fresh();
      await store.addTags(['cat']);
      await expectLater(
        store.addTags(['dog', 'two tags']),
        throwsFormatException,
      );
      expect(store.tags, ['cat']);
      await store.addTags(['bird']);
      expect(store.tags, ['bird', 'cat']);
    },
  );

  test(
    'corrupt saved rules remain exportable and cannot be overwritten',
    () async {
      const damaged = '{"version":1,"enabled":true,"tags":[42]}';
      final store = await fresh({TagBlocklist.storageKey: damaged});
      expect(store.loadError, isNotNull);
      expect(await store.rawBackup(), damaged);
      await expectLater(store.addTags(['cat']), throwsStateError);
      expect(await store.rawBackup(), damaged);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        TagBlocklist.storageKey,
        jsonEncode({
          'version': 1,
          'enabled': true,
          'tags': ['dog'],
        }),
      );
      await store.retryLoad();
      expect(store.loadError, isNull);
      expect(store.hides('dog'), isTrue);
    },
  );

  test(
    'wrong-type preferences can still be backed up without losing type',
    () async {
      final store = await fresh({TagBlocklist.storageKey: 42});
      expect(store.loadError, isNotNull);
      expect(jsonDecode(await store.rawBackup()), {'value': 42});
    },
  );

  test(
    'adding a rule ends temporary reveal without deleting any rules',
    () async {
      final store = await fresh();
      await store.addTags(['cat']);
      store.setTemporarilyShow(true);
      await store.addTags(['dog']);
      expect(store.temporarilyShow, isFalse);
      expect(store.hides('cat'), isTrue);
      expect(store.hides('dog'), isTrue);
    },
  );

  test(
    'a detail action saves its new rule and enabled state together',
    () async {
      final store = await fresh();
      await store.setEnabled(false);
      await store.addTags(['cat']);
      expect(store.hides('cat'), isFalse);
      await store.addTags(['dog'], enableFiltering: true);
      expect(store.enabled, isTrue);
      expect(store.hides('cat dog'), isTrue);
      final saved = jsonDecode(await store.rawBackup());
      expect(saved['enabled'], isTrue);
      expect(saved['tags'], ['cat', 'dog']);
    },
  );

  test(
    'overlapping retries cannot publish a stale snapshot after a write',
    () async {
      final platform = _DelayedReadsStore();
      final preferences = await platform.install();
      final store = TagBlocklist(loadPreferences: () async => preferences);
      await store.initialize();
      await store.addTags(['cat']);
      platform.holdReads = true;
      final firstRetry = store.retryLoad();
      await Future<void>.delayed(Duration.zero);
      final secondRetry = store.retryLoad();
      final addition = store.addTags(['dog']);
      await Future<void>.delayed(Duration.zero);
      expect(platform.pendingReads, hasLength(1));
      platform.pendingReads.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(platform.pendingReads, hasLength(2));
      expect(store.tags, ['cat']);
      platform.pendingReads.last.complete();
      await Future.wait([firstRetry, secondRetry, addition]);
      platform.holdReads = false;
      expect(store.tags, ['cat', 'dog']);
      expect(jsonDecode(await store.rawBackup())['tags'], ['cat', 'dog']);
      store.dispose();
    },
  );

  test(
    'undoing deletion can retain the current temporary reveal state',
    () async {
      final store = await fresh();
      await store.addTags(['cat']);
      store.setTemporarilyShow(true);
      await store.removeTags(['cat']);
      await store.addTags(['cat'], endTemporaryReveal: false);
      expect(store.temporarilyShow, isTrue);
      expect(store.hides('cat'), isFalse);
      expect(store.tags, ['cat']);
    },
  );
}
