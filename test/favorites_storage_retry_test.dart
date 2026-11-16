import 'dart:convert';

import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/favorites_page.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/failing_preferences_store.dart';
import 'support/fake_completion_service.dart';
import 'support/native_memory_preferences_store.dart';

const _fullKey = 'favorite_posts_full';
Map<String, Object> _post(int id) => {'id': id, 'rating': 'g'};

// The original native commit mutates memory, then fails. The platform channel
// becomes unavailable before rollback can reach native memory.
class _UnavailableRollbackStore extends NativeMemoryPreferencesStore {
  _UnavailableRollbackStore(super.initialValues);

  bool writesAvailable = false;
  bool _attempted = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (_attempted && !writesAvailable) {
      throw StateError('The preferences platform channel is unavailable');
    }
    _attempted = true;
    return super.setValue(valueType, key, value);
  }
}

Future<void> _open(
  WidgetTester tester,
  SharedPreferences preferences,
  FavoritesManager manager, {
  bool dark = false,
  Size size = const Size(375, 812),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final rules = TagBlocklist(loadPreferences: () async => preferences);
  await rules.initialize();
  final network = AppNetworkService.forTesting(
    clientFactory: (_) => MockClient((_) async => http.Response('[]', 200)),
  );
  addTearDown(rules.dispose);
  addTearDown(network.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(2),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: FavoritesPage(
        manager: manager,
        blocklist: rules,
        networkService: network,
        completionService: FakeCompletionService(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('explicit retry reads repaired collection data', (tester) async {
    const damaged = '[{"id":42';
    final backend = FailingPreferencesStore({_fullKey: damaged});
    final preferences = await backend.install();
    final manager = FavoritesManager.forTesting(preferences);
    await _open(tester, preferences, manager);
    expect(find.text('收藏暂时无法读取'), findsOneWidget);

    final repaired = jsonEncode([_post(42)]);
    backend.persisted[_fullKey] = repaired;
    // Ordinary reads still use the confirmed snapshot, not a global reload.
    await expectLater(
      manager.getFavoritePostIds(),
      throwsA(isA<FavoritesDataException>()),
    );
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('收藏暂时无法读取'), findsNothing);
    expect(find.text('图片 (1)'), findsOneWidget);
    expect(find.byTooltip('取消收藏作品 #42'), findsOneWidget);
    expect(backend.persisted[_fullKey], repaired);
    expect(tester.takeException(), isNull);
  });

  testWidgets('header refresh explicitly rereads confirmed storage', (
    tester,
  ) async {
    final backend = FailingPreferencesStore({_fullKey: '[]'});
    final preferences = await backend.install();
    final manager = FavoritesManager.forTesting(preferences);
    await _open(
      tester,
      preferences,
      manager,
      dark: true,
      size: const Size(1200, 600),
    );
    expect(find.text('还没有收藏的图片'), findsOneWidget);

    backend.persisted[_fullKey] = jsonEncode([_post(7)]);
    expect(await manager.getFavoritePostIds(), isEmpty);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();

    expect(find.text('图片 (1)'), findsOneWidget);
    expect(find.byTooltip('取消收藏作品 #7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry cannot accept an unconfirmed failed native write', (
    tester,
  ) async {
    final original = jsonEncode([_post(1)]);
    final backend = _UnavailableRollbackStore({_fullKey: original});
    final preferences = await backend.install();
    final manager = FavoritesManager.forTesting(preferences);
    await _open(tester, preferences, manager);
    backend.failures[_fullKey] = PreferenceFailure.returnFalse;
    await expectLater(manager.addFavorite(_post(2)), throwsStateError);
    final dirty = backend.nativeMemory[_fullKey];
    expect(jsonDecode(dirty! as String), [_post(2), _post(1)]);
    expect(backend.persisted[_fullKey], original);

    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('收藏暂时无法读取'), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('收藏暂时无法读取'), findsOneWidget);
    expect(find.text('图片 (1)'), findsOneWidget);
    expect(await manager.getFavoritePostIds(), [1]);
    expect(backend.nativeMemory[_fullKey], dirty);
    expect(backend.persisted[_fullKey], original);

    backend.failures.clear();
    backend.writesAvailable = true;
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('收藏暂时无法读取'), findsNothing);
    expect(find.byTooltip('取消收藏作品 #1'), findsOneWidget);
    expect(find.byTooltip('取消收藏作品 #2'), findsNothing);
    expect(backend.nativeMemory[_fullKey], original);
    expect(backend.persisted[_fullKey], original);
    expect(tester.takeException(), isNull);
  });
}
