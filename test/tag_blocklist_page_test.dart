import 'dart:convert';

import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:danbooru_viewer/tag_blocklist_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets(
    'rules can be added, deduplicated, searched, removed and undone',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = TagBlocklist(loadPreferences: () async => preferences);
      await store.initialize();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(home: TagBlocklistPage(blocklist: store)),
      );
      await tester.enterText(_field('添加屏蔽标签'), 'cat\nblue_hair cat');
      await tester.tap(find.text('添加标签'));
      await tester.pumpAndSettle();
      expect(store.tags, ['blue_hair', 'cat']);
      expect(find.text('已保存 2 个标签'), findsOneWidget);
      await tester.enterText(_field('查找屏蔽标签'), 'cat');
      await tester.pumpAndSettle();
      expect(find.byTooltip('解除屏蔽 blue_hair'), findsNothing);
      await tester.ensureVisible(find.byTooltip('解除屏蔽 cat'));
      await tester.tap(find.byTooltip('解除屏蔽 cat'));
      await tester.pumpAndSettle();
      expect(store.tags, ['blue_hair']);
      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(store.tags, ['blue_hair', 'cat']);
      final saved = jsonDecode(preferences.getString(TagBlocklist.storageKey)!);
      expect(saved['version'], 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('undo remains functional after leaving the settings page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = TagBlocklist(loadPreferences: () async => preferences);
    await store.initialize();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => TagBlocklistPage(blocklist: store),
                ),
              ),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('添加屏蔽标签'), 'cat');
    await tester.tap(find.text('添加标签'));
    await tester.pumpAndSettle();
    expect(store.tags, ['cat']);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(TagBlocklistPage), findsNothing);
    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(store.tags, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'settings are scrollable at 200 percent text in a short window, dark=$dark',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final store = TagBlocklist(loadPreferences: () async => preferences);
        await store.initialize();
        await store.addTags(['a_very_long_tag_${'x' * 100}']);
        addTearDown(store.dispose);
        tester.view.physicalSize = const Size(320, 300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: TagBlocklistPage(blocklist: store),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('添加标签'));
        await tester.pumpAndSettle();
        expect(find.text('添加标签').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
