import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/full_screen_image_page.dart';
import 'package:danbooru_viewer/post.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:danbooru_viewer/video_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class _Video extends VideoPlayerController {
  _Video({bool pending = false})
    : super.networkUrl(Uri.parse('https://example.test/a.mp4')) {
    if (!pending) initialized.complete();
  }
  final initialized = Completer<void>();
  int pauseCalls = 0;
  int disposeCalls = 0;
  @override
  Future<void> initialize() => initialized.future;
  @override
  Future<void> pause() async {
    pauseCalls++;
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }
}

Post _post(int id, String tags, {String? fileUrl}) => Post(
  id: id,
  rating: 'g',
  tagString: tags,
  tagStringGeneral: tags,
  fileUrl: fileUrl,
);

Future<TagBlocklist> _store({
  List<String> tags = const [],
  bool enabled = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = TagBlocklist();
  await store.initialize();
  if (tags.isNotEmpty) await store.addTags(tags);
  if (!enabled) await store.setEnabled(false);
  addTearDown(store.dispose);
  return store;
}

void _viewport(WidgetTester tester, [Size size = const Size(600, 900)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<FavoritesManager> _manager() async =>
    FavoritesManager.forTesting(await SharedPreferences.getInstance());

void main() {
  for (final sameSource in [false, true]) {
    for (final waitForDrag in [false, true]) {
      testWidgets(
        'full-screen holds stay with their post when filtering replaces it '
        '(same source: $sameSource, wait for drag: $waitForDrag)',
        (tester) async {
          _viewport(tester);
          final store = await _store();
          const sourceA = '/cache/cat.mp4';
          final sourceB = sameSource ? sourceA : '/cache/dog.mp4';
          const dragChannel = MethodChannel(
            'com.alicejump.danbooru_viewer/drag',
          );
          final dragCalls = <MethodCall>[];
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(dragChannel, (call) async {
            dragCalls.add(call);
            return true;
          });
          addTearDown(
            () => messenger.setMockMethodCallHandler(dragChannel, null),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: FullScreenImagePage(
                previewUrl: '',
                heroTag: 'hold-filter',
                posts: [
                  _post(100, 'cat', fileUrl: sourceA),
                  _post(200, 'dog', fileUrl: sourceB),
                ],
                blocklist: store,
                videoControllerFactory: (_) => _Video(),
              ),
            ),
          );
          await tester.pumpAndSettle();

          Offset holdPosition() =>
              tester.getRect(find.byType(DanbooruVideoPlayer)).topCenter +
              const Offset(0, 20);

          final oldHold = await tester.startGesture(holdPosition());
          await tester.pump(const Duration(milliseconds: 600));
          await store.addTags(['cat']);
          await tester.pumpAndSettle();
          expect(find.text('#200'), findsOneWidget);
          if (waitForDrag) {
            await tester.pump(const Duration(milliseconds: 1100));
          }
          expect(dragCalls, isEmpty);
          await oldHold.up();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(dragCalls, isEmpty);

          // The replacement keeps its own normal hold behavior: a new long
          // hold drags B, and a new shorter hold opens B's save flow.
          final newDrag = await tester.startGesture(holdPosition());
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 1100));
          expect(dragCalls, hasLength(1));
          expect(dragCalls.single.method, 'startDrag');
          expect(dragCalls.single.arguments, {
            'path': sourceB,
            'type': 'video',
          });
          await newDrag.up();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          final newSave = await tester.startGesture(holdPosition());
          await tester.pump(const Duration(milliseconds: 600));
          await newSave.up();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(dragCalls, hasLength(1));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }

  testWidgets(
    'detail captures scoped store, preserves raw IDs and restores hidden posts',
    (tester) async {
      _viewport(tester);
      final store = await _store(tags: ['cat']);
      final posts = [_post(100, 'cat'), _post(200, 'dog'), _post(300, 'bird')];
      await tester.pumpWidget(
        MaterialApp(
          home: TagBlocklistScope(
            blocklist: store,
            child: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => openPostDetailPage(
                    context: context,
                    posts: posts,
                    initialIndex: 1,
                    completionDisplayByValue: const {},
                  ),
                  child: const Text('打开详情'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PostDetailPage>(find.byType(PostDetailPage)).blocklist,
        same(store),
      );
      expect(find.text('Post #200'), findsOneWidget);
      await store.addTags(['dog']);
      await tester.pumpAndSettle();
      expect(find.text('Post #300'), findsOneWidget);
      await store.removeTags(['cat']);
      await tester.pumpAndSettle();
      expect(find.text('Post #300'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('Post #100'), findsOneWidget);
      await store.addTags(['cat', 'bird']);
      await tester.pumpAndSettle();
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
      await store.removeTags(['bird']);
      await tester.pumpAndSettle();
      expect(find.text('Post #300'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail waits for stored rules and never initializes an initially blocked video',
    (tester) async {
      _viewport(tester);
      SharedPreferences.setMockInitialValues({
        TagBlocklist.storageKey: '{"version":1,"enabled":true,"tags":["cat"]}',
      });
      final preferences = await SharedPreferences.getInstance();
      final pending = Completer<SharedPreferences>();
      final store = TagBlocklist(loadPreferences: () => pending.future);
      addTearDown(store.dispose);
      var created = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: [_post(7, 'cat', fileUrl: 'https://example.test/a.mp4')],
            initialIndex: 0,
            completionDisplayByValue: const {},
            blocklist: store,
            favoritesManager: FavoritesManager.forTesting(preferences),
            videoControllerFactory: (_) {
              created++;
              return _Video();
            },
          ),
        ),
      );
      expect(created, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pending.complete(preferences);
      await tester.pumpAndSettle();
      expect(created, 0);
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      await store.removeTags(['cat']);
      await tester.pumpAndSettle();
      expect(created, 1);
      expect(find.text('Post #7'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail maps a full-screen post ID after rules changed in the other route',
    (tester) async {
      _viewport(tester);
      final store = await _store(tags: ['cat']);
      final posts = [
        _post(100, 'cat', fileUrl: 'https://example.test/cat.mp4'),
        _post(200, 'dog', fileUrl: 'https://example.test/dog.mp4'),
        _post(300, 'bird', fileUrl: 'https://example.test/bird.mp4'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: posts,
            initialIndex: 1,
            completionDisplayByValue: const {},
            blocklist: store,
            favoritesManager: await _manager(),
            videoControllerFactory: (_) => _Video(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Post #200'), findsOneWidget);
      await tester.tap(find.byTooltip('全屏'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('#300'), findsOneWidget);
      await store.removeTags(['cat']);
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
      await store.addTags(['cat', 'dog', 'bird']);
      await tester.pumpAndSettle();
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      await store.removeTags(['cat', 'dog', 'bird']);
      // Close before the restored parent pager has attached its first frame.
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == '关闭全屏 (Esc)',
            ),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('Post #300'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale detail callbacks retain the clicked ID and reject newly hidden media',
    (tester) async {
      _viewport(tester);
      final store = await _store();
      final manager = await _manager();
      final posts = [
        _post(100, 'cat', fileUrl: 'https://example.test/cat.mp4'),
        _post(200, 'dog', fileUrl: 'https://example.test/dog.mp4'),
        _post(300, 'bird', fileUrl: 'https://example.test/bird.mp4'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: posts,
            initialIndex: 1,
            completionDisplayByValue: const {},
            blocklist: store,
            favoritesManager: manager,
            videoControllerFactory: (_) => _Video(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final openDog = tester
          .widget<DanbooruVideoPlayer>(find.byType(DanbooruVideoPlayer))
          .onOpenFullScreen!;
      final next = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '下一张 (→)',
            ),
          )
          .onPressed!;
      await store.addTags(['cat']);
      // Rule notifications have rebuilt the list, but the previous frame's
      // controls can still be tapped before the new pager attaches.
      next();
      openDog();
      await tester.pumpAndSettle();
      expect(find.text('#200'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Post #200'), findsOneWidget);

      final reopenDog = tester
          .widget<DanbooruVideoPlayer>(find.byType(DanbooruVideoPlayer))
          .onOpenFullScreen!;
      final saveDog = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '保存原图或视频',
            ),
          )
          .onPressed!;
      final favoriteDog = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '收藏',
            ),
          )
          .onPressed!;
      final shareDog = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '分享',
            ),
          )
          .onPressed!;
      final mediaRect = tester.getRect(find.byType(DanbooruVideoPlayer));
      final hold = await tester.startGesture(
        mediaRect.topCenter + const Offset(0, 20),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await store.addTags(['dog']);
      reopenDog();
      saveDog();
      favoriteDog();
      shareDog();
      await hold.up();
      await tester.pumpAndSettle();
      expect(find.byType(FullScreenImagePage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Post #300'), findsOneWidget);
      expect(await manager.isFavorite(200), isFalse);
      expect(await manager.isFavorite(300), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail filters legacy category tags when the aggregate is absent',
    (tester) async {
      _viewport(tester);
      final store = await _store(tags: ['cat']);
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: [
              Post(id: 10, rating: 'g', tagString: '', tagStringGeneral: 'Cat'),
            ],
            initialIndex: 0,
            completionDisplayByValue: const {},
            blocklist: store,
            favoritesManager: await _manager(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hiding a playing detail video pauses immediately and releases it',
    (tester) async {
      _viewport(tester);
      final store = await _store();
      final video = _Video();
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: [_post(7, 'cat', fileUrl: 'https://example.test/a.mp4')],
            initialIndex: 0,
            completionDisplayByValue: const {},
            blocklist: store,
            favoritesManager: await _manager(),
            videoControllerFactory: (_) => video,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DanbooruVideoPlayer), findsOneWidget);
      video.value = video.value.copyWith(isPlaying: true);
      final before = video.pauseCalls;
      await store.addTags(['cat']);
      expect(video.pauseCalls, greaterThan(before));
      expect(video.value.isPlaying, isFalse);
      await tester.pumpAndSettle();
      expect(video.disposeCalls, 1);
      expect(find.byType(DanbooruVideoPlayer), findsNothing);
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a hidden pending video never reappears when initialization completes',
    (tester) async {
      _viewport(tester);
      final store = await _store();
      final video = _Video(pending: true);
      var created = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: [_post(7, 'cat', fileUrl: 'https://example.test/a.mp4')],
            initialIndex: 0,
            completionDisplayByValue: const {},
            blocklist: store,
            favoritesManager: await _manager(),
            videoControllerFactory: (_) {
              created++;
              return video;
            },
          ),
        ),
      );
      expect(created, 1);
      await store.addTags(['cat']);
      await tester.pump();
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      video.initialized.complete();
      await tester.pumpAndSettle();
      expect(video.disposeCalls, 1);
      expect(find.byType(DanbooruVideoPlayer), findsNothing);
      expect(created, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'visible keyboard menu blocks the canonical tag and undo restores reveal',
    (tester) async {
      _viewport(tester);
      final handle = tester.ensureSemantics();
      final store = await _store(enabled: false);
      store.setTemporarilyShow(true);
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: [_post(9, 'Blue_Hair')],
            initialIndex: 0,
            completionDisplayByValue: const {'blue_hair': '蓝发'},
            blocklist: store,
            favoritesManager: await _manager(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final menu = find.byTooltip('标签操作 Blue_Hair');
      await tester.ensureVisible(menu);
      for (
        var index = 0;
        index < 20 &&
            tester.getSemantics(menu).flagsCollection.isFocused !=
                Tristate.isTrue;
        index++
      ) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(
        tester.getSemantics(menu).flagsCollection.isFocused,
        Tristate.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('屏蔽此标签'));
      await tester.pumpAndSettle();
      expect(store.tags, ['blue_hair']);
      expect(store.enabled, isTrue);
      expect(store.temporarilyShow, isFalse);
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(store.tags, isEmpty);
      expect(store.enabled, isFalse);
      expect(store.temporarilyShow, isTrue);
      expect(find.text('Post #9'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    },
  );

  testWidgets('undo remains safe after the detail route is disposed', (
    tester,
  ) async {
    _viewport(tester);
    final store = await _store();
    final manager = await _manager();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => PostDetailPage(
                    posts: [_post(8, 'cat')],
                    initialIndex: 0,
                    completionDisplayByValue: const {},
                    blocklist: store,
                    favoritesManager: manager,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('标签操作 cat'));
    await tester.tap(find.byTooltip('标签操作 cat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('屏蔽此标签'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PostDetailPage), findsNothing);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(store.tags, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'full screen preserves raw selection, restores rules and returns a post ID',
    (tester) async {
      _viewport(tester);
      final store = await _store(tags: ['cat']);
      final posts = [_post(110, 'cat'), _post(220, 'dog'), _post(330, 'bird')];
      int? returnedId;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  returnedId = await Navigator.push<int>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FullScreenImagePage(
                        previewUrl: '',
                        heroTag: 'post_220',
                        posts: posts,
                        initialIndex: 1,
                        blocklist: store,
                      ),
                    ),
                  );
                },
                child: const Text('打开全屏'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开全屏'));
      await tester.pumpAndSettle();
      expect(find.text('#220'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('#330'), findsOneWidget);
      await store.addTags(['bird']);
      await tester.pumpAndSettle();
      expect(find.text('#220'), findsOneWidget);
      await store.removeTags(['cat']);
      await tester.pumpAndSettle();
      expect(find.text('#220'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('#110'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(returnedId, 110);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'full screen hides all media without falling back to the blocked original URL',
    (tester) async {
      _viewport(tester, const Size(320, 300));
      final store = await _store(tags: ['cat']);
      var created = 0;
      final video = _Video();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: FullScreenImagePage(
            previewUrl: '',
            highResUrl: 'https://example.test/a.mp4',
            heroTag: 'post_7',
            posts: [_post(7, 'cat', fileUrl: 'https://example.test/a.mp4')],
            blocklist: store,
            videoControllerFactory: (_) {
              created++;
              return video;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(created, 0);
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      final save = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '保存原图或视频',
        ),
      );
      expect(save.onPressed, isNull);
      expect(tester.takeException(), isNull);
      store.setTemporarilyShow(true);
      await tester.pumpAndSettle();
      expect(created, 1);
      expect(find.byType(DanbooruVideoPlayer), findsOneWidget);
      final before = video.pauseCalls;
      store.setTemporarilyShow(false);
      expect(video.pauseCalls, greaterThan(before));
      await tester.pumpAndSettle();
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      expect(video.disposeCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
