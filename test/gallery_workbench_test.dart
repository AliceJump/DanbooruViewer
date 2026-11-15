import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/main.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/fake_completion_service.dart';

http.Response _posts({int first = 1, int count = 1}) => http.Response(
  jsonEncode([
    for (var id = first; id < first + count; id++)
      {'id': id, 'rating': 'g', 'tag_string': 'landscape'},
  ]),
  200,
);

Finder _post(int id) => find.byWidgetPredicate(
  (widget) => widget is PostThumbnailTile && widget.heroTag == 'post_$id',
);

Future<void> _pumpWorkbench(
  WidgetTester tester,
  Future<http.Response> Function(Uri) fetch, {
  FakeCompletionService? service,
  Size size = const Size(800, 700),
  double textScale = 1,
  bool dark = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: MyHomePage(
        title: 'Danbooru Viewer',
        fetchPosts: fetch,
        completionService: service ?? FakeCompletionService(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _focusSearch(
  WidgetTester tester, {
  LogicalKeyboardKey modifier = LogicalKeyboardKey.controlLeft,
}) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  testWidgets('an HTTP error offers retry instead of an empty-result message', (
    tester,
  ) async {
    var requests = 0;
    await _pumpWorkbench(tester, (_) async {
      requests++;
      return requests == 1 ? http.Response('unavailable', 503) : _posts();
    });

    expect(find.text('作品加载失败'), findsOneWidget);
    expect(find.text('暂无结果'), findsNothing);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(_post(1), findsOneWidget);
    expect(find.text('作品加载失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a network failure can recover to a genuine empty result', (
    tester,
  ) async {
    var requests = 0;
    await _pumpWorkbench(tester, (_) async {
      if (++requests == 1) throw http.ClientException('offline');
      return http.Response('[]', 200);
    });

    expect(find.text('作品加载失败'), findsOneWidget);
    expect(find.text('暂无结果'), findsNothing);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(find.text('暂无结果'), findsOneWidget);
    expect(find.text('作品加载失败'), findsNothing);
  });

  testWidgets(
    'failed pagination retains posts and retries the same page once',
    (tester) async {
      final requests = <Uri>[];
      var pageTwoAttempts = 0;
      await _pumpWorkbench(tester, (uri) async {
        requests.add(uri);
        if (uri.queryParameters['page'] == '1') return _posts(count: 100);
        if (++pageTwoAttempts == 1) return http.Response('unavailable', 500);
        return _posts(first: 101);
      });

      await tester.drag(find.byType(GridView), const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(requests.map((uri) => uri.queryParameters['page']), ['1', '2']);
      expect(_post(100), findsOneWidget);
      expect(find.text('重试加载'), findsOneWidget);

      await tester.drag(find.byType(GridView), const Offset(0, 300));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(GridView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));

      await tester.tap(find.text('重试加载'));
      await tester.pumpAndSettle();
      expect(requests.map((uri) => uri.queryParameters['page']), [
        '1',
        '2',
        '2',
      ]);
      expect(find.text('重试加载'), findsNothing);
      // The first page must remain reachable after the second page is appended.
      await tester.drag(find.byType(GridView), const Offset(0, 20000));
      await tester.pumpAndSettle();
      expect(_post(1), findsOneWidget);
    },
  );

  testWidgets('refresh preserves the current gallery while pending or failed', (
    tester,
  ) async {
    final refreshing = Completer<http.Response>();
    var requests = 0;
    await _pumpWorkbench(tester, (_) {
      requests++;
      if (requests == 2) return refreshing.future;
      return Future.value(requests == 1 ? _posts() : http.Response('[]', 200));
    });

    await tester.tap(find.byTooltip('刷新作品'));
    await tester.pump();
    expect(requests, 2);
    expect(_post(1), findsOneWidget);

    refreshing.complete(http.Response('unavailable', 500));
    await tester.pumpAndSettle();
    expect(_post(1), findsOneWidget);
    expect(find.text('重试加载'), findsOneWidget);
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();

    expect(requests, 3);
    expect(_post(1), findsNothing);
    expect(find.text('暂无结果'), findsOneWidget);
    expect(find.text('重试加载'), findsNothing);
  });

  testWidgets('pull to refresh replaces the gallery even when it is short', (
    tester,
  ) async {
    var requests = 0;
    await _pumpWorkbench(tester, (_) async => _posts(first: ++requests));
    expect(_post(1), findsOneWidget);

    await tester.drag(find.byType(GridView), const Offset(0, 450));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(_post(1), findsNothing);
    expect(_post(2), findsOneWidget);
  });

  testWidgets('pagination keeps the submitted query when the draft changes', (
    tester,
  ) async {
    final requests = <Uri>[];
    await _pumpWorkbench(tester, (uri) async {
      requests.add(uri);
      return uri.queryParameters['page'] == '1'
          ? _posts(count: 100)
          : http.Response('[]', 200);
    });
    await tester.enterText(find.byType(TextField), 'landscape');
    await tester.tap(find.byTooltip('搜索作品'));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['tags'], 'landscape');

    await tester.enterText(find.byType(TextField), 'unsubmitted_draft');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.drag(find.byType(GridView), const Offset(0, -20000));
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['page'], '2');
    expect(requests.last.queryParameters['tags'], 'landscape');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'unsubmitted_draft',
    );
  });

  testWidgets('a stale refresh cannot replace results from a newer filter', (
    tester,
  ) async {
    final refresh = Completer<http.Response>();
    var requests = 0;
    await _pumpWorkbench(tester, (_) {
      requests++;
      if (requests == 2) return refresh.future;
      return Future.value(_posts(first: requests == 1 ? 1 : 3));
    });

    await tester.tap(find.byTooltip('刷新作品'));
    await tester.pump();
    await tester.tap(find.text('全年龄 (R-0)'));
    await tester.pump();
    expect(_post(3), findsOneWidget);

    refresh.complete(_posts(first: 2));
    await tester.pumpAndSettle();
    expect(_post(3), findsOneWidget);
    expect(_post(2), findsNothing);
  });

  testWidgets('keyboard search and Escape preserve the draft and selection', (
    tester,
  ) async {
    await _pumpWorkbench(tester, (_) async => _posts());
    await tester.tap(find.byTooltip('选择作品'));
    await tester.pump();
    expect(find.byTooltip('退出多选'), findsOneWidget);

    await _focusSearch(tester);
    var field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), 'draft_query');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isFalse);
    expect(field.controller!.text, 'draft_query');
    expect(find.byTooltip('退出多选'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byTooltip('退出多选'), findsNothing);
    expect(find.byTooltip('选择作品'), findsOneWidget);

    await _focusSearch(tester, modifier: LogicalKeyboardKey.metaLeft);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  });

  testWidgets(
    'clearing search removes submitted chips and the draft together',
    (tester) async {
      final requests = <Uri>[];
      await _pumpWorkbench(tester, (uri) async {
        requests.add(uri);
        return _posts();
      });
      await tester.enterText(find.byType(TextField), 'landscape');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'landscape'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'another_draft');
      await tester.tap(find.text('清空搜索'));
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['tags'], isEmpty);
      expect(find.byType(InputChip), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'short large-text viewport retains a usable grid after refresh fails',
    (tester) async {
      var attempts = 0;
      await _pumpWorkbench(
        tester,
        (_) async {
          attempts++;
          return attempts == 1
              ? _posts(count: 6)
              : http.Response('unavailable', 503);
        },
        size: const Size(320, 300),
        textScale: 2,
      );
      await tester.ensureVisible(find.byTooltip('刷新作品'));
      await tester.tap(find.byTooltip('刷新作品'));
      await tester.pumpAndSettle();
      expect(find.text('重试加载'), findsOneWidget);
      expect(find.text('重试加载').hitTestable(), findsOneWidget);
      expect(tester.getSize(find.byType(GridView)).height, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, size, dark) in [
    ('small phone', const Size(375, 812), false),
    ('short viewport', const Size(320, 300), false),
    ('wide dark desktop', const Size(1440, 900), true),
  ]) {
    testWidgets('$name supports long tags and 200% text without overflow', (
      tester,
    ) async {
      final longTag = List.filled(16, 'a_very_long_character_name').join('_');
      final requests = <Uri>[];
      await _pumpWorkbench(
        tester,
        (uri) async {
          requests.add(uri);
          return _posts(count: 6);
        },
        size: size,
        textScale: 2,
        dark: dark,
      );
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), longTag);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(requests.last.queryParameters['tags'], longTag);
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      expect(tester.getSize(find.byType(GridView)).height, greaterThan(0));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(TextField)).width,
        lessThanOrEqualTo(size.width),
      );
    });
  }
}
