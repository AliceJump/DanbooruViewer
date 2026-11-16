import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/favorites_page.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:danbooru_viewer/tag_blocklist_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/failing_preferences_store.dart';
import 'support/fake_completion_service.dart';

Map<String, Object> _post(int id, String tags) => {
  'id': id,
  'rating': 'g',
  'tag_string': tags,
};

class _Fixture {
  _Fixture({
    required this.backend,
    required this.preferences,
    required this.manager,
    required this.rules,
    required this.network,
    required this.requests,
  });

  final FailingPreferencesStore backend;
  final SharedPreferences preferences;
  final FavoritesManager manager;
  final TagBlocklist rules;
  final AppNetworkService network;
  final List<Uri> requests;

  static Future<_Fixture> create({
    Map<String, Object> values = const {},
    List<String> blocked = const [],
    Map<String, List<Map<String, Object>>> previews = const {},
  }) async {
    final backend = FailingPreferencesStore(values);
    final preferences = await backend.install();
    final manager = FavoritesManager.forTesting(preferences);
    final rules = TagBlocklist(loadPreferences: () async => preferences);
    await rules.initialize();
    if (blocked.isNotEmpty) await rules.addTags(blocked);
    final requests = <Uri>[];
    final network = AppNetworkService.forTesting(
      maxAttempts: 1,
      retryDelay: Duration.zero,
      clientFactory: (_) => MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode(previews[request.url.queryParameters['tags']] ?? []),
          200,
        );
      }),
    );
    addTearDown(rules.dispose);
    addTearDown(network.dispose);
    return _Fixture(
      backend: backend,
      preferences: preferences,
      manager: manager,
      rules: rules,
      network: network,
      requests: requests,
    );
  }
}

class _DelayedRemoveManager extends FavoritesManager {
  _DelayedRemoveManager(super.preferences) : super.forTesting();

  final pending = Completer<void>();

  @override
  Future<void> removeFavorite(int postId) => pending.future;
}

Future<void> _pump(
  WidgetTester tester,
  _Fixture fixture, {
  Size size = const Size(375, 812),
  double textScale = 1,
  bool dark = false,
  FavoritesManager? manager,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    TagBlocklistScope(
      blocklist: fixture.rules,
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: FavoritesPage(
          manager: manager ?? fixture.manager,
          networkService: fixture.network,
          completionService: FakeCompletionService(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _tile(String label) => find.byWidgetPredicate(
  (widget) => widget is PostThumbnailTile && widget.semanticLabel == label,
);

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _tab(WidgetTester tester, String label) async {
  final tab = find.text(label);
  await tester.ensureVisible(tab);
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String fieldLabel, String tag) async {
  await tester.enterText(_field(fieldLabel), tag);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'favorites, history and cached tag previews filter without deleting raw data',
    (tester) async {
      final favorites = jsonEncode([_post(1, 'cat'), _post(2, 'cat_ears')]);
      final history = jsonEncode([_post(3, 'cat'), _post(4, 'dog')]);
      final tags = jsonEncode([
        {'tag': 'landscape', 'category': 0},
      ]);
      final fixture = await _Fixture.create(
        values: {
          'favorite_posts_full': favorites,
          'browsing_history_posts': history,
          'favorite_tags_v2': tags,
        },
        blocked: ['cat'],
        previews: {
          'landscape': [_post(5, 'cat'), _post(6, 'dog')],
        },
      );
      await _pump(tester, fixture);

      expect(_tile('收藏作品 #1'), findsNothing);
      expect(_tile('收藏作品 #2'), findsOneWidget);
      expect(find.text('已屏蔽 1 项'), findsOneWidget);
      await _tab(tester, '历史 (2)');
      expect(_tile('浏览记录作品 #3'), findsNothing);
      expect(_tile('浏览记录作品 #4'), findsOneWidget);
      await tester.tap(find.text('临时显示').hitTestable());
      await tester.pumpAndSettle();
      expect(_tile('浏览记录作品 #3'), findsOneWidget);
      await tester.tap(find.text('恢复屏蔽').hitTestable());
      await tester.pumpAndSettle();

      await _tab(tester, '标签 (1)');
      expect(find.text('landscape'), findsOneWidget);
      expect(_tile('作品 #5'), findsNothing);
      expect(_tile('作品 #6'), findsOneWidget);
      final requestsBeforeChange = fixture.requests.length;
      await fixture.rules.removeTags(['cat']);
      await tester.pumpAndSettle();
      expect(_tile('作品 #5'), findsOneWidget);
      expect(fixture.requests, hasLength(requestsBeforeChange));
      await fixture.rules.addTags(['cat', 'dog']);
      await tester.pumpAndSettle();
      expect(find.text('预览已被屏蔽'), findsOneWidget);
      expect(find.text('暂无预览'), findsNothing);
      expect(find.text('landscape'), findsOneWidget);

      expect(fixture.preferences.getString('favorite_posts_full'), favorites);
      expect(fixture.preferences.getString('browsing_history_posts'), history);
      expect(fixture.preferences.getString('favorite_tags_v2'), tags);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'committed collection filters match complete canonical tag tokens',
    (tester) async {
      final raw = jsonEncode([
        _post(1, 'cat blue'),
        _post(2, 'cat_ears blue'),
        _post(3, 'cat green'),
      ]);
      final fixture = await _Fixture.create(
        values: {'favorite_posts_full': raw, 'browsing_history_posts': raw},
      );
      await _pump(tester, fixture);
      await _submit(tester, '筛选收藏图片', 'CAT');
      expect(_tile('收藏作品 #1'), findsOneWidget);
      expect(_tile('收藏作品 #2'), findsNothing);
      expect(_tile('收藏作品 #3'), findsOneWidget);
      await _submit(tester, '筛选收藏图片', 'blue');
      expect(_tile('收藏作品 #1'), findsOneWidget);
      expect(_tile('收藏作品 #3'), findsNothing);

      await _tab(tester, '历史 (3)');
      await _submit(tester, '筛选浏览历史', 'cat');
      expect(_tile('浏览记录作品 #1'), findsOneWidget);
      expect(_tile('浏览记录作品 #2'), findsNothing);
      expect(_tile('浏览记录作品 #3'), findsOneWidget);
      expect(fixture.preferences.getString('favorite_posts_full'), raw);
      expect(fixture.preferences.getString('browsing_history_posts'), raw);
    },
  );

  testWidgets(
    'failed collection mutations retain the visible records and report the error',
    (tester) async {
      final favorites = jsonEncode([_post(1, 'cat')]);
      final history = jsonEncode([_post(2, 'dog')]);
      final tags = jsonEncode([
        {'tag': 'landscape', 'category': 0},
      ]);
      final fixture = await _Fixture.create(
        values: {
          'favorite_posts_full': favorites,
          'browsing_history_posts': history,
          'favorite_tags_v2': tags,
        },
      );
      fixture.backend.setFailures['favorite_posts_full'] =
          PreferenceFailure.returnFalse;
      fixture.backend.setFailures['favorite_tags_v2'] =
          PreferenceFailure.throwException;
      fixture.backend.removeFailures['browsing_history_posts'] =
          PreferenceFailure.returnFalse;
      await _pump(tester, fixture);

      await tester.tap(find.byTooltip('取消收藏作品 #1'));
      await tester.pumpAndSettle();
      expect(_tile('收藏作品 #1'), findsOneWidget);
      expect(find.text('更改未能保存，原有收藏和历史已保留，请重试。'), findsOneWidget);
      expect(fixture.preferences.getString('favorite_posts_full'), favorites);
      ScaffoldMessenger.of(
        tester.element(find.byType(FavoritesPage)),
      ).clearSnackBars();
      await tester.pumpAndSettle();

      await _tab(tester, '标签 (1)');
      await tester.tap(find.byTooltip('取消收藏标签'));
      await tester.pumpAndSettle();
      expect(find.text('landscape'), findsOneWidget);
      expect(find.text('更改未能保存，原有收藏和历史已保留，请重试。'), findsOneWidget);
      expect(fixture.preferences.getString('favorite_tags_v2'), tags);
      ScaffoldMessenger.of(
        tester.element(find.byType(FavoritesPage)),
      ).clearSnackBars();
      await tester.pumpAndSettle();

      await _tab(tester, '历史 (1)');
      await tester.tap(find.text('清空浏览历史'));
      await tester.pumpAndSettle();
      expect(_tile('浏览记录作品 #2'), findsOneWidget);
      expect(find.text('更改未能保存，原有收藏和历史已保留，请重试。'), findsOneWidget);
      expect(fixture.preferences.getString('browsing_history_posts'), history);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy category-only tags are screened in collections and previews',
    (tester) async {
      const oldPost = {'id': 7, 'tag_string_general': 'cat'};
      final raw = jsonEncode([oldPost]);
      final fixture = await _Fixture.create(
        values: {
          'favorite_posts_full': raw,
          'browsing_history_posts': raw,
          'favorite_tags_v2': jsonEncode([
            {'tag': 'landscape', 'category': 0},
          ]),
        },
        blocked: ['cat'],
        previews: {
          'landscape': [oldPost],
        },
      );
      await _pump(tester, fixture);
      expect(find.text('收藏作品已被屏蔽'), findsOneWidget);
      await _tab(tester, '历史 (1)');
      expect(find.text('浏览记录已被屏蔽'), findsOneWidget);
      await _tab(tester, '标签 (1)');
      expect(find.text('预览已被屏蔽'), findsOneWidget);
      expect(_tile('作品 #7'), findsNothing);
      expect(fixture.preferences.getString('favorite_posts_full'), raw);
      expect(fixture.preferences.getString('browsing_history_posts'), raw);
    },
  );

  testWidgets(
    'damaged collections can be copied from the error state and app bar',
    (tester) async {
      const damaged = '[{"id":42';
      final fixture = await _Fixture.create(
        values: {'favorite_posts_full': damaged},
      );
      String? clipboard;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _pump(tester, fixture);
      expect(find.text('收藏暂时无法读取'), findsOneWidget);

      await tester.tap(find.byTooltip('复制收藏备份'));
      await tester.pumpAndSettle();
      expect(jsonDecode(clipboard!)['values']['favorite_posts_full'], damaged);
      clipboard = null;
      await tester.ensureVisible(find.text('复制备份'));
      await tester.tap(find.text('复制备份'));
      await tester.pumpAndSettle();
      expect(jsonDecode(clipboard!)['values']['favorite_posts_full'], damaged);
      expect(fixture.preferences.getString('favorite_posts_full'), damaged);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legacy ID-only collections expose recovery and raw backup', (
    tester,
  ) async {
    const raw = '[42,99]';
    final fixture = await _Fixture.create(values: {'favorite_posts': raw});
    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _pump(tester, fixture);
    expect(
      find.text(const LegacyFavoritesRecoveryException().toString()),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('复制备份'));
    await tester.tap(find.text('复制备份'));
    await tester.pumpAndSettle();
    expect(jsonDecode(clipboard!)['values'], {'favorite_posts': raw});
    expect(fixture.backend.persisted['favorite_posts'], raw);
    expect(
      fixture.backend.persisted.containsKey('favorite_posts_full'),
      isFalse,
    );
    expect(fixture.backend.setCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail receives raw matching posts and clicked ID, then refreshes on return',
    (tester) async {
      final fixture = await _Fixture.create(
        values: {
          'favorite_posts_full': jsonEncode([_post(1, 'cat'), _post(2, 'dog')]),
        },
        blocked: ['cat'],
      );
      await _pump(tester, fixture);
      await tester.tap(_tile('收藏作品 #2'));
      await tester.pumpAndSettle();
      final detail = tester.widget<PostDetailPage>(find.byType(PostDetailPage));
      expect(detail.posts.map((post) => post.id), [1, 2]);
      expect(detail.posts[detail.initialIndex].id, 2);
      expect(identical(detail.blocklist, fixture.rules), isTrue);

      await fixture.manager.removeFavorite(2);
      Navigator.of(tester.element(find.byType(PostDetailPage))).pop();
      await tester.pumpAndSettle();
      expect(_tile('收藏作品 #2'), findsNothing);
      expect(find.text('收藏作品已被屏蔽'), findsOneWidget);
      expect(await fixture.manager.getFavoritePostIds(), [1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finishing a collection mutation after leaving the page is safe',
    (tester) async {
      final fixture = await _Fixture.create(
        values: {
          'favorite_posts_full': jsonEncode([_post(1, 'cat')]),
        },
      );
      final manager = _DelayedRemoveManager(fixture.preferences);
      await _pump(tester, fixture, manager: manager);
      await tester.tap(find.byTooltip('取消收藏作品 #1'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      manager.pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'blocklist controls fit a 320x300 viewport at 200 percent text, dark=$dark',
      (tester) async {
        final fixture = await _Fixture.create(
          values: {
            'favorite_posts_full': jsonEncode([
              _post(1, 'cat'),
              _post(2, 'dog'),
            ]),
            'browsing_history_posts': jsonEncode([_post(3, 'cat')]),
          },
          blocked: ['cat'],
        );
        await _pump(
          tester,
          fixture,
          size: const Size(320, 300),
          textScale: 2,
          dark: dark,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('临时显示'));
        await tester.tap(find.text('临时显示').hitTestable());
        await tester.pumpAndSettle();
        expect(fixture.rules.temporarilyShow, isTrue);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('管理屏蔽'));
        await tester.tap(find.text('管理屏蔽').hitTestable());
        await tester.pumpAndSettle();
        final settings = tester.widget<TagBlocklistPage>(
          find.byType(TagBlocklistPage),
        );
        expect(identical(settings.blocklist, fixture.rules), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
