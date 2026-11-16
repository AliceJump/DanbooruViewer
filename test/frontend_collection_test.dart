import 'dart:convert';
import 'dart:ui' show PointerDeviceKind, Tristate;

import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/favorites_page.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_completion_service.dart';

Future<void> pumpCollection(
  WidgetTester tester, {
  double textScale = 1,
  Size size = const Size(375, 812),
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Scenarios seed the platform directly; explicitly refresh the shared
  // confirmed snapshot after these external fixture changes.
  await FavoritesManager().reload();
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: FavoritesPage(completionService: FakeCompletionService()),
    ),
  );
  await tester.pumpAndSettle();
}

Finder filterField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> submitFilter(
  WidgetTester tester,
  String label,
  String query,
) async {
  await tester.enterText(filterField(label), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  late SharedPreferences preferences;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  const post = {'id': 42, 'rating': 'g', 'tag_string': 'blue_hair'};

  // FavoritesManager owns a serial Future queue. Keep collection scenarios in
  // one FakeAsync zone so a completed queue tail cannot outlive its test clock.
  // Each scenario still gets a fresh route and cleared persistent fixtures.
  testWidgets(
    'collection filters, controls and large-text layout remain usable',
    (tester) async {
      Future<void> scenario(String name, Future<void> Function() body) async {
        debugPrint('Collection scenario: $name');
        await preferences.clear();
        await body();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 350));
      }

      await scenario('favorite no-matches and clear', () async {
        await preferences.setString('favorite_posts_full', jsonEncode([post]));
        await pumpCollection(tester);
        expect(find.byType(PostThumbnailTile), findsOneWidget);
        await submitFilter(tester, '筛选收藏图片', 'unmatched_tag');
        expect(find.text('没有匹配的收藏'), findsOneWidget);
        expect(find.text('还没有收藏的图片'), findsNothing);
        await tester.tap(find.byTooltip('清空收藏筛选'));
        await tester.pumpAndSettle();
        expect(find.byType(PostThumbnailTile), findsOneWidget);
        expect(
          jsonDecode(preferences.getString('favorite_posts_full')!),
          hasLength(1),
        );
      });

      await scenario('history no-matches and clear', () async {
        await preferences.setString(
          'browsing_history_posts',
          jsonEncode([post]),
        );
        await pumpCollection(tester);
        await tester.tap(find.text('历史 (1)'));
        await tester.pumpAndSettle();
        await submitFilter(tester, '筛选浏览历史', 'unmatched_tag');
        expect(find.text('没有匹配的浏览记录'), findsOneWidget);
        expect(find.text('还没有浏览历史'), findsNothing);
        await tester.tap(find.byTooltip('清空历史筛选'));
        await tester.pumpAndSettle();
        expect(find.byType(PostThumbnailTile), findsOneWidget);
        expect(
          jsonDecode(preferences.getString('browsing_history_posts')!),
          hasLength(1),
        );
      });

      for (final history in [false, true]) {
        await scenario(
          'mouse selects ${history ? 'history' : 'favorite'} suggestion',
          () async {
            await preferences.setString(
              history ? 'browsing_history_posts' : 'favorite_posts_full',
              jsonEncode([post]),
            );
            await pumpCollection(tester);
            if (history) {
              await tester.tap(find.text('历史 (1)'));
              await tester.pumpAndSettle();
            }
            final field = filterField(history ? '筛选浏览历史' : '筛选收藏图片');
            await tester.enterText(field, 'blue');
            await tester.pumpAndSettle();
            final suggestion = find.widgetWithText(ListTile, 'blue_hair');
            expect(suggestion, findsOneWidget);
            final position = tester.getCenter(suggestion);
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: position);
            try {
              await mouse.down(position);
              await tester.pump();
              expect(
                tester.widget<TextField>(field).focusNode!.hasFocus,
                isTrue,
              );
              expect(suggestion, findsOneWidget);
              await mouse.up();
              await tester.pumpAndSettle();
              expect(
                find.widgetWithText(InputChip, 'blue_hair'),
                findsOneWidget,
              );
              expect(tester.widget<TextField>(field).controller!.text, isEmpty);
              expect(find.byType(PostThumbnailTile), findsOneWidget);
            } finally {
              await mouse.removePointer();
            }
          },
        );
      }

      await scenario('tag category and query reset', () async {
        await preferences.setString(
          'favorite_tags_v2',
          jsonEncode([
            {'tag': 'blue_hair', 'category': 0},
          ]),
        );
        await pumpCollection(tester);
        await tester.tap(find.text('标签 (1)'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, '角色'));
        await tester.enterText(filterField('筛选收藏标签'), 'unmatched_tag');
        await tester.pumpAndSettle();
        expect(find.text('没有匹配的收藏标签'), findsOneWidget);
        await tester.tap(find.byTooltip('清空标签筛选'));
        await tester.pumpAndSettle();
        expect(find.text('blue_hair'), findsOneWidget);
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
              .selected,
          isTrue,
        );
      });

      await scenario('48px remove target without a preview', () async {
        await preferences.setString('favorite_posts_full', jsonEncode([post]));
        await pumpCollection(tester);
        final remove = find.byTooltip('取消收藏作品 #42');
        final size = tester.getSize(remove);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(find.text('还没有收藏的图片'), findsOneWidget);
        expect(
          jsonDecode(preferences.getString('favorite_posts_full')!),
          isEmpty,
        );
      });

      for (final dark in [false, true]) {
        await scenario('320px at 200% text, dark=$dark', () async {
          await preferences.setString(
            'favorite_posts_full',
            jsonEncode([post]),
          );
          await pumpCollection(
            tester,
            size: const Size(320, 480),
            textScale: 2,
            dark: dark,
          );
          final longTag = List.filled(12, 'very_long_character_name').join('_');
          await submitFilter(tester, '筛选收藏图片', longTag);
          expect(tester.takeException(), isNull);
          expect(find.byType(InputChip), findsOneWidget);
          expect(
            tester.getSize(find.byType(InputChip)).width,
            lessThanOrEqualTo(288),
          );
          await tester.ensureVisible(find.byType(InputChip));
          await tester.tap(find.byType(InputChip));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.widgetWithText(SelectableText, longTag), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    },
  );

  testWidgets(
    'missing-preview thumbnail keeps pointer, keyboard and selection semantics',
    (tester) async {
      var taps = 0;
      var longPresses = 0;
      var overlayTaps = 0;
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 160,
                  height: 160,
                  child: PostThumbnailTile(
                    previewUrl: null,
                    highResUrl: null,
                    heroTag: 'missing-preview',
                    semanticLabel: '作品 #42',
                    selected: true,
                    onTap: () => taps++,
                    onLongPress: () => longPresses++,
                    overlay: Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        tooltip: '删除测试作品',
                        onPressed: () => overlayTaps++,
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final tile = find.byType(PostThumbnailTile);
        expect(
          tester.getSemantics(tile).flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(tester.getSemantics(tile).flagsCollection.isButton, isTrue);
        await tester.tap(tile);
        await tester.longPress(tile);
        expect(taps, 1);
        expect(longPresses, 1);
        await tester.tap(find.byTooltip('删除测试作品'));
        expect(overlayTaps, 1);
        expect(taps, 1);

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(taps, 2);
      } finally {
        semantics.dispose();
      }
    },
  );
}
