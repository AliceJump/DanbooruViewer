import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/download_progress_dialog.dart';
import 'package:danbooru_viewer/main.dart';
import 'package:danbooru_viewer/media_save_service.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_completion_service.dart';
import 'support/failing_preferences_store.dart';

class _PendingBlocklistWrite extends FailingPreferencesStore {
  final started = Completer<void>();
  final _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.${TagBlocklist.storageKey}') {
      if (!started.isCompleted) started.complete();
      await _release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

http.Response postsResponse(List<(int, String)> posts) => http.Response(
  jsonEncode([
    for (final (id, tags) in posts)
      {'id': id, 'rating': 'g', 'tag_string': tags},
  ]),
  200,
);

Future<TagBlocklist> blocklistWith(List<String> tags) async {
  SharedPreferences.setMockInitialValues({});
  final store = TagBlocklist();
  await store.initialize();
  if (tags.isNotEmpty) await store.addTags(tags);
  return store;
}

Future<void> showHome(
  WidgetTester tester,
  TagBlocklist store,
  Future<http.Response> Function(Uri) fetch, {
  MediaSaver? saveMedia,
}) async {
  await tester.pumpWidget(
    TagBlocklistScope(
      blocklist: store,
      child: MaterialApp(
        home: MyHomePage(
          title: 'test',
          completionService: FakeCompletionService(),
          fetchPosts: fetch,
          saveMedia: saveMedia,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> visibleIds(WidgetTester tester) => tester
    .widgetList<PostThumbnailTile>(find.byType(PostThumbnailTile))
    .map((tile) => tile.heroTag)
    .toList();

void main() {
  for (final hideBeforeRetry in [false, true]) {
    testWidgets(
      'pending rule writes skip queued downloads and preserve retry selections (hide retry: $hideBeforeRetry)',
      (tester) async {
        final backend = _PendingBlocklistWrite();
        final preferences = await backend.install();
        final store = TagBlocklist(loadPreferences: () async => preferences);
        await store.initialize();
        final activeSave = Completer<MediaSaveResult>();
        addTearDown(() {
          backend.release();
          if (!activeSave.isCompleted) {
            activeSave.complete(
              const MediaSaveResult(destination: 'Downloads', isVideo: true),
            );
          }
          store.dispose();
          SharedPreferences.setMockInitialValues({});
        });
        final attempts = <int>[];
        var failThird = true;
        await showHome(
          tester,
          store,
          (_) async => http.Response(
            jsonEncode([
              for (final (id, tag) in [
                (1, 'landscape'),
                (2, 'cat'),
                (3, 'dog'),
              ])
                {
                  'id': id,
                  'rating': 'g',
                  'tag_string': tag,
                  // No thumbnail request is needed for these video tiles.
                  'file_url': 'https://example.test/$id.mp4',
                },
            ]),
            200,
          ),
          saveMedia: (source, {postId, cancelToken, onProgress}) async {
            attempts.add(postId!);
            if (postId == 1) return activeSave.future;
            if (postId == 3 && failThird) {
              throw const MediaSaveException('模拟保存失败');
            }
            return const MediaSaveResult(
              destination: 'Downloads',
              isVideo: true,
            );
          },
        );

        // A settings route can already have popped while its write is pending.
        final pendingWrite = store.addTags(['cat']);
        await tester.pump();
        expect(backend.started.isCompleted, isTrue);
        expect(store.hides('cat'), isFalse);
        await tester.longPress(find.byKey(const ValueKey('post_1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('post_2')));
        await tester.tap(find.byKey(const ValueKey('post_3')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下载选中作品'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(attempts, [1]);

        backend.release();
        await tester.pump();
        await pendingWrite;
        expect(store.hides('cat'), isTrue);
        activeSave.complete(
          const MediaSaveResult(destination: 'Downloads', isVideo: true),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(attempts, [1, 3]);
        expect(find.text('#2 · 已跳过'), findsOneWidget);
        expect(find.text('作品已隐藏，未开始保存。'), findsOneWidget);
        expect(find.text('已保存 1 / 3 项'), findsOneWidget);

        if (hideBeforeRetry) {
          await store.addTags(['dog']);
          // Even a retry button drawn before this write must recheck rules.
          await tester.tap(find.text('重试未完成项'));
          await tester.pumpAndSettle();
          expect(attempts, [1, 3]);
          expect(find.text('#3 · 已跳过'), findsOneWidget);
          expect(find.text('重试未完成项'), findsNothing);
        }
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        if (!hideBeforeRetry) {
          expect(find.text('1 已选择'), findsOneWidget);
          final selected = tester
              .widgetList<PostThumbnailTile>(find.byType(PostThumbnailTile))
              .where((tile) => tile.selected == true)
              .map((tile) => tile.heroTag);
          expect(selected, ['post_3']);
          failThird = false;
          await tester.tap(find.byTooltip('下载选中作品'));
          await tester.pumpAndSettle();
          expect(attempts, [1, 3, 3]);
          await tester.tap(find.text('完成'));
          await tester.pumpAndSettle();
        }
        expect(find.byTooltip('退出多选'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('exact local rules refilter retained results without refetch', (
    tester,
  ) async {
    final store = await blocklistWith(['cat']);
    final requests = <Uri>[];
    await showHome(tester, store, (uri) async {
      requests.add(uri);
      return postsResponse([(1, 'cat solo'), (2, 'cat_ears'), (3, 'dog')]);
    });

    expect(visibleIds(tester), ['post_2', 'post_3']);
    expect(requests.single.queryParameters['tags'], '');
    store.setTemporarilyShow(true);
    await tester.pumpAndSettle();
    expect(visibleIds(tester), ['post_1', 'post_2', 'post_3']);
    store.setTemporarilyShow(false);
    await tester.pumpAndSettle();
    expect(visibleIds(tester), ['post_2', 'post_3']);
    await store.removeTags(['cat']);
    await tester.pumpAndSettle();
    expect(visibleIds(tester), ['post_1', 'post_2', 'post_3']);
    expect(requests, hasLength(1));
  });

  testWidgets('fully blocked pages advance to the next visible raw page', (
    tester,
  ) async {
    final store = await blocklistWith(['cat']);
    final requestedPages = <String>[];
    await showHome(tester, store, (uri) async {
      final page = uri.queryParameters['page']!;
      requestedPages.add(page);
      return postsResponse([(int.parse(page), page == '3' ? 'dog' : 'cat')]);
    });
    expect(requestedPages, ['1', '2', '3']);
    expect(visibleIds(tester), ['post_3']);
    expect(find.text('已屏蔽 2 项'), findsOneWidget);
  });

  testWidgets('lookahead is bounded and only a raw empty page ends paging', (
    tester,
  ) async {
    final store = await blocklistWith(['cat']);
    final requestedPages = <int>[];
    await showHome(tester, store, (uri) async {
      final page = int.parse(uri.queryParameters['page']!);
      requestedPages.add(page);
      return postsResponse(page < 7 ? [(page, 'cat')] : []);
    });
    expect(requestedPages, [1, 2, 3]);
    expect(find.text('当前作品均被屏蔽'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('continue_filtered_pages')),
    );
    await tester.tap(find.byKey(const ValueKey('continue_filtered_pages')));
    await tester.pumpAndSettle();
    expect(requestedPages, [1, 2, 3, 4, 5, 6]);

    await tester.ensureVisible(
      find.byKey(const ValueKey('continue_filtered_pages')),
    );
    await tester.tap(find.byKey(const ValueKey('continue_filtered_pages')));
    await tester.pumpAndSettle();
    expect(requestedPages, [1, 2, 3, 4, 5, 6, 7]);
    expect(find.byKey(const ValueKey('continue_filtered_pages')), findsNothing);
    expect(find.textContaining('已到最后一页'), findsOneWidget);
    store.setTemporarilyShow(true);
    await tester.pumpAndSettle();
    expect(visibleIds(tester), hasLength(6));
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets('lookahead failure retries the failed page and keeps raw data', (
    tester,
  ) async {
    final store = await blocklistWith(['cat']);
    final requestedPages = <String>[];
    var failed = false;
    await showHome(tester, store, (uri) async {
      final page = uri.queryParameters['page']!;
      requestedPages.add(page);
      if (page == '2' && !failed) {
        failed = true;
        return http.Response('unavailable', 503);
      }
      return postsResponse([(int.parse(page), page == '1' ? 'cat' : 'dog')]);
    });
    expect(requestedPages, ['1', '2']);
    expect(find.text('作品加载失败'), findsOneWidget);
    await tester.ensureVisible(find.text('重新加载'));
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(requestedPages, ['1', '2', '2']);
    expect(visibleIds(tester), ['post_2']);
    await store.removeTags(['cat']);
    await tester.pumpAndSettle();
    expect(visibleIds(tester), ['post_1', 'post_2']);
  });

  testWidgets('empty multi-select survives a rule change', (tester) async {
    final store = await blocklistWith([]);
    await showHome(
      tester,
      store,
      (_) async => postsResponse([(1, 'cat'), (2, 'dog')]),
    );
    await tester.tap(find.byTooltip('选择作品'));
    await tester.pumpAndSettle();
    expect(find.text('0 已选择'), findsOneWidget);

    await store.addTags(['cat']);
    await tester.pumpAndSettle();
    expect(visibleIds(tester), ['post_2']);
    expect(find.text('0 已选择'), findsOneWidget);
    expect(find.byTooltip('退出多选'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('post_2')));
    await tester.pumpAndSettle();
    expect(find.text('1 已选择'), findsOneWidget);
    expect(find.byType(PostDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty multi-select survives loading another page', (
    tester,
  ) async {
    final store = await blocklistWith([]);
    final requestedPages = <int>[];
    await showHome(tester, store, (uri) async {
      final page = int.parse(uri.queryParameters['page']!);
      requestedPages.add(page);
      return postsResponse(page == 1 ? [(1, 'cat')] : [(2, 'dog')]);
    });
    await tester.tap(find.byTooltip('选择作品'));
    await tester.pumpAndSettle();
    expect(find.text('0 已选择'), findsOneWidget);

    await tester.tap(find.byTooltip('加载更多'));
    await tester.pumpAndSettle();
    expect(requestedPages, [1, 2]);
    expect(visibleIds(tester), ['post_1', 'post_2']);
    expect(find.text('0 已选择'), findsOneWidget);
    expect(find.byTooltip('退出多选'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('post_2')));
    await tester.pumpAndSettle();
    expect(find.text('1 已选择'), findsOneWidget);
    expect(find.byType(PostDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new rules remove hidden selections immediately', (tester) async {
    final store = await blocklistWith([]);
    await showHome(
      tester,
      store,
      (_) async => postsResponse([(1, 'cat'), (2, 'dog')]),
    );
    await tester.longPress(find.byKey(const ValueKey('post_1')));
    await tester.pumpAndSettle();
    expect(find.text('1 已选择'), findsOneWidget);
    await store.addTags(['cat']);
    await tester.pumpAndSettle();
    expect(visibleIds(tester), ['post_2']);
    expect(find.text('1 已选择'), findsNothing);
    expect(find.byTooltip('下载选中作品'), findsNothing);
  });

  testWidgets('a stale tile callback revalidates its ID after rules change', (
    tester,
  ) async {
    final store = await blocklistWith([]);
    await showHome(
      tester,
      store,
      (_) async => postsResponse([(1, 'cat'), (2, 'dog')]),
    );
    final hiddenTile = tester.widget<PostThumbnailTile>(
      find.byKey(const ValueKey('post_1')),
    );
    final retainedTile = tester.widget<PostThumbnailTile>(
      find.byKey(const ValueKey('post_2')),
    );
    await store.addTags(['cat']);
    // Rules notify synchronously; the old rendered callbacks still exist
    // until the next frame. Neither an old index nor a hidden ID is valid.
    hiddenTile.onLongPress?.call();
    hiddenTile.onTap?.call();
    retainedTile.onTap?.call();
    await tester.pumpAndSettle();
    final detail = tester.widget<PostDetailPage>(find.byType(PostDetailPage));
    expect(detail.posts[detail.initialIndex].id, 2);
    expect(find.text('1 已选择'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a stale filtered lookahead cannot append or request more pages',
    (tester) async {
      final store = await blocklistWith(['cat']);
      final pending = Completer<http.Response>();
      final requests = <Uri>[];
      await tester.pumpWidget(
        TagBlocklistScope(
          blocklist: store,
          child: MaterialApp(
            home: MyHomePage(
              title: 'test',
              completionService: FakeCompletionService(),
              fetchPosts: (uri) async {
                requests.add(uri);
                if (uri.queryParameters['tags'] == 'rating:g') {
                  return postsResponse([(10, 'dog')]);
                }
                if (uri.queryParameters['page'] == '1') {
                  return postsResponse([(1, 'cat')]);
                }
                return pending.future;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(requests, hasLength(2));
      await tester.tap(find.text('全年龄 (R-0)'));
      await tester.pumpAndSettle();
      expect(visibleIds(tester), ['post_10']);
      pending.complete(postsResponse([(2, 'cat')]));
      await tester.pumpAndSettle();
      expect(requests, hasLength(3));
      expect(visibleIds(tester), ['post_10']);
    },
  );
}
