import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/post.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/failing_preferences_store.dart';

class _FailSecondFavoriteWrite extends FailingPreferencesStore {
  int favoriteAttempts = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.favorite_posts_full' && ++favoriteAttempts == 2) {
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

Future<void> _open(WidgetTester tester, FailingPreferencesStore backend) async {
  tester.view.physicalSize = const Size(600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final preferences = await backend.install();
  final store = TagBlocklist(loadPreferences: () async => preferences);
  await store.initialize();
  addTearDown(store.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: PostDetailPage(
        posts: [
          Post(id: 42, rating: 'g', tagString: 'cat', tagStringGeneral: 'cat'),
        ],
        initialIndex: 0,
        completionDisplayByValue: const {},
        blocklist: store,
        favoritesManager: FavoritesManager.forTesting(preferences),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('detail catches a corrupt favorite lookup and retains raw data', (
    tester,
  ) async {
    const damaged = 'unreadable favorite records';
    final backend = FailingPreferencesStore({'favorite_posts_full': damaged});
    await _open(tester, backend);
    expect(find.text('收藏状态无法读取，原始数据已保留。'), findsOneWidget);
    expect(backend.persisted['favorite_posts_full'], damaged);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legacy favorite IDs show their state and explain blocked edits',
    (tester) async {
      const raw = '[42,99]';
      final backend = FailingPreferencesStore({'favorite_posts': raw});
      await _open(tester, backend);
      expect(find.byTooltip('取消收藏'), findsOneWidget);
      await tester.tap(find.byTooltip('取消收藏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('取消收藏'), findsOneWidget);
      expect(
        find.text(const LegacyFavoritesRecoveryException().toString()),
        findsOneWidget,
      );
      expect(backend.persisted['favorite_posts'], raw);
      expect(backend.persisted.containsKey('favorite_posts_full'), isFalse);
      expect(
        backend.setCalls.where((key) => key.startsWith('favorite_posts')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail catches history write failure without preventing browsing',
    (tester) async {
      final backend = FailingPreferencesStore();
      backend.setFailures['browsing_history_posts'] =
          PreferenceFailure.throwException;
      await _open(tester, backend);
      expect(find.text('Post #42'), findsOneWidget);
      expect(find.text('浏览历史未能保存，本次浏览仍可继续。'), findsOneWidget);
      expect(backend.persisted.containsKey('browsing_history_posts'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed favorite toggle shows feedback and permits a correct retry',
    (tester) async {
      final backend = FailingPreferencesStore();
      backend.setFailures['favorite_posts_full'] =
          PreferenceFailure.returnFalse;
      await _open(tester, backend);
      await tester.tap(find.byTooltip('收藏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('收藏'), findsOneWidget);
      expect(find.text('收藏未能保存，原有收藏保持不变，请重试。'), findsOneWidget);
      expect(backend.persisted.containsKey('favorite_posts_full'), isFalse);
      backend.setFailures.clear();
      await tester.tap(find.byTooltip('收藏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('取消收藏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tag favorite write failure is caught after closing the menu', (
    tester,
  ) async {
    final backend = FailingPreferencesStore();
    backend.setFailures['favorite_tags_v2'] = PreferenceFailure.throwException;
    await _open(tester, backend);
    await tester.ensureVisible(find.byTooltip('标签操作 cat'));
    await tester.tap(find.byTooltip('标签操作 cat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏标签'));
    await tester.pumpAndSettle();
    expect(find.text('标签收藏未能保存，原有收藏保持不变，请重试。'), findsOneWidget);
    expect(backend.persisted.containsKey('favorite_tags_v2'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid favorite activation cannot queue a conflicting write', (
    tester,
  ) async {
    final backend = _FailSecondFavoriteWrite();
    await _open(tester, backend);
    final activate = tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '收藏',
          ),
        )
        .onPressed!;
    activate();
    activate();
    await tester.pumpAndSettle();
    expect(backend.favoriteAttempts, 1);
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed block action leaves the post visible and reports the write error',
    (tester) async {
      final backend = FailingPreferencesStore();
      backend.setFailures[TagBlocklist.storageKey] =
          PreferenceFailure.returnFalse;
      await _open(tester, backend);
      await tester.ensureVisible(find.byTooltip('标签操作 cat'));
      await tester.tap(find.byTooltip('标签操作 cat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('屏蔽此标签'));
      await tester.pumpAndSettle();
      expect(find.text('Post #42'), findsOneWidget);
      expect(find.text('屏蔽标签未能保存，原有规则保持不变，请重试。'), findsOneWidget);
      expect(backend.persisted.containsKey(TagBlocklist.storageKey), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
