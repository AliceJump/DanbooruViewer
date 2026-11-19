import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/main.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:flutter/gestures.dart';
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
  bool disableAnimations = true,
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
          disableAnimations: disableAnimations,
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

Future<void> _dragGalleryWithoutFling(
  WidgetTester tester,
  double distance,
) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(GridView)),
  );
  await gesture.moveBy(Offset(0, distance));
  // Stop the finger before lifting it so inertia does not turn a small
  // direction change into a second, much longer gesture.
  await tester.pump(const Duration(milliseconds: 250));
  await gesture.up();
  await tester.pumpAndSettle();
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

  testWidgets('mobile scrolling gives images space and restores controls', (
    tester,
  ) async {
    var requests = 0;
    await _pumpWorkbench(
      tester,
      (_) async {
        requests++;
        return _posts(count: 100);
      },
      size: const Size(375, 812),
      disableAnimations: false,
    );
    final initialHeight = tester.getSize(find.byType(GridView)).height;
    final controller = tester
        .widget<GridView>(find.byType(GridView))
        .controller!;

    await _dragGalleryWithoutFling(tester, -180);

    expect(find.byType(TextField).hitTestable(), findsNothing);
    expect(find.byTooltip('展开搜索与筛选').hitTestable(), findsOneWidget);
    expect(
      tester.getSize(find.byType(GridView)).height,
      greaterThan(initialHeight + 100),
    );
    expect(
      tester.widget<GridView>(find.byType(GridView)).controller,
      same(controller),
    );
    expect(requests, 1);

    await _dragGalleryWithoutFling(tester, 90);

    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(find.byTooltip('收起搜索与筛选').hitTestable(), findsOneWidget);
    expect(
      tester.getSize(find.byType(GridView)).height,
      closeTo(initialHeight, 1),
    );
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small gallery reversals do not flicker mobile controls', (
    tester,
  ) async {
    await _pumpWorkbench(
      tester,
      (_) async => _posts(count: 100),
      size: const Size(375, 812),
    );
    await _dragGalleryWithoutFling(tester, -180);
    final collapsedHeight = tester.getSize(find.byType(GridView)).height;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(GridView)),
    );
    for (final distance in [22.0, -12.0, 12.0, -12.0, 12.0]) {
      await gesture.moveBy(Offset(0, distance));
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byType(TextField).hitTestable(), findsNothing);
      expect(
        tester.getSize(find.byType(GridView)).height,
        closeTo(collapsedHeight, 1),
      );
    }
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile search toggle preserves draft and gallery position', (
    tester,
  ) async {
    final requests = <Uri>[];
    await _pumpWorkbench(tester, (uri) async {
      requests.add(uri);
      return _posts(count: 100);
    }, size: const Size(375, 812));
    await tester.enterText(find.byType(TextField), 'landscape');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unsubmitted_draft');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _dragGalleryWithoutFling(tester, -220);

    final controller = tester
        .widget<GridView>(find.byType(GridView))
        .controller!;
    final position = controller.offset;
    final requestCount = requests.length;
    expect(find.byType(TextField).hitTestable(), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.textContaining('landscape'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.textContaining('unsubmitted_draft'),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('mobile_search_toggle')));
    await tester.pumpAndSettle();

    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(controller.offset, closeTo(position, 1));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'unsubmitted_draft',
    );
    expect(find.widgetWithText(InputChip, 'landscape'), findsOneWidget);
    expect(requests, hasLength(requestCount));
    expect(requests.last.queryParameters['tags'], 'landscape');
    expect(tester.takeException(), isNull);
  });

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('${modifier.keyLabel}+F reveals a collapsed mobile search', (
      tester,
    ) async {
      await _pumpWorkbench(
        tester,
        (_) async => _posts(count: 100),
        size: const Size(375, 812),
      );
      await _dragGalleryWithoutFling(tester, -180);
      expect(find.byType(TextField).hitTestable(), findsNothing);

      await _focusSearch(tester, modifier: modifier);
      await tester.pumpAndSettle();

      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('gallery wheel scrolling keeps an active search editor visible', (
    tester,
  ) async {
    await _pumpWorkbench(
      tester,
      (_) async => _posts(count: 100),
      size: const Size(375, 812),
    );
    await tester.enterText(find.byType(TextField), 'draft_query');
    await tester.pumpAndSettle();
    final controller = tester
        .widget<GridView>(find.byType(GridView))
        .controller!;

    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: tester.getCenter(find.byType(GridView)),
        scrollDelta: const Offset(0, 180),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsing mobile controls retains the selected work', (
    tester,
  ) async {
    await _pumpWorkbench(
      tester,
      (_) async => _posts(count: 100),
      size: const Size(375, 812),
    );
    await tester.longPress(_post(1));
    await tester.pumpAndSettle();
    expect(find.text('1 已选择'), findsOneWidget);

    await _dragGalleryWithoutFling(tester, -180);

    expect(find.text('1 已选择'), findsOneWidget);
    expect(find.byTooltip('退出多选').hitTestable(), findsOneWidget);
    expect(find.byTooltip('下载选中作品').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出多选'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scrolling completion suggestions does not collapse the gallery',
    (tester) async {
      await _pumpWorkbench(
        tester,
        (_) async => _posts(count: 100),
        size: const Size(375, 812),
        service: FakeCompletionService(
          onBootstrap: () async => [
            for (var index = 0; index < 30; index++)
              SearchCompletionSuggestion(
                value: 'landscape_$index',
                insertValue: 'landscape_$index',
                source: 'tag',
                score: 30 - index,
                category: 0,
              ),
          ],
        ),
      );
      await _focusSearch(tester);
      await tester.pumpAndSettle();
      final gallery = find.byType(GridView);
      final initialHeight = tester.getSize(gallery).height;
      final controller = tester.widget<GridView>(gallery).controller!;

      await tester.drag(find.byType(ListView), const Offset(0, -160));
      await tester.pumpAndSettle();

      final suggestionsScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(suggestionsScroll.position.pixels, greaterThan(0));
      expect(controller.offset, 0);
      expect(tester.getSize(gallery).height, closeTo(initialHeight, 1));
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short dark large-text screen can reclaim space without motion', (
    tester,
  ) async {
    await _pumpWorkbench(
      tester,
      (_) async => _posts(count: 100),
      size: const Size(320, 300),
      textScale: 2,
      dark: true,
    );
    final initialHeight = tester.getSize(find.byType(GridView)).height;
    final toggle = find.byKey(const ValueKey('mobile_search_toggle'));
    expect(toggle.hitTestable(), findsOneWidget);
    expect(tester.getSize(toggle).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));

    await tester.tap(toggle);
    await tester.pump();

    expect(find.byType(TextField).hitTestable(), findsNothing);
    expect(
      tester.getSize(find.byType(GridView)).height,
      greaterThan(initialHeight + 50),
    );
    expect(toggle.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(toggle);
    await tester.pump();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop gallery scrolling keeps the search sidebar available', (
    tester,
  ) async {
    await _pumpWorkbench(
      tester,
      (_) async => _posts(count: 100),
      size: const Size(1440, 900),
      dark: true,
    );
    final fieldRect = tester.getRect(find.byType(TextField));
    final gridRect = tester.getRect(find.byType(GridView));

    await _dragGalleryWithoutFling(tester, -180);

    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byType(TextField)), fieldRect);
    expect(tester.getRect(find.byType(GridView)), gridRect);
    expect(find.byKey(const ValueKey('mobile_search_toggle')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'resizing a collapsed gallery preserves a reachable search draft',
    (tester) async {
      var requests = 0;
      await _pumpWorkbench(tester, (_) async {
        requests++;
        return _posts(count: 100);
      }, size: const Size(375, 812));
      await tester.enterText(find.byType(TextField), 'kept_draft');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _dragGalleryWithoutFling(tester, -180);
      expect(find.byType(TextField).hitTestable(), findsNothing);

      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();

      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'kept_draft',
      );
      expect(find.byKey(const ValueKey('mobile_search_toggle')), findsNothing);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(375, 812);
      await tester.pumpAndSettle();

      expect(find.byTooltip('展开搜索与筛选').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('展开搜索与筛选'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'kept_draft');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(requests, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resizing chrome at the loaded end does not reopen or fetch', (
    tester,
  ) async {
    final requestedPages = <String?>[];
    await _pumpWorkbench(
      tester,
      (uri) async {
        final page = uri.queryParameters['page'];
        requestedPages.add(page);
        return page == '1' ? _posts(count: 12) : http.Response('[]', 200);
      },
      size: const Size(375, 812),
      disableAnimations: false,
    );
    await _dragGalleryWithoutFling(tester, -2000);
    expect(requestedPages, ['1', '2']);
    final controller = tester
        .widget<GridView>(find.byType(GridView))
        .controller!;
    final toggle = find.byKey(const ValueKey('mobile_search_toggle'));
    expect(find.byType(TextField).hitTestable(), findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final expandedEnd = controller.offset;

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(controller.offset, lessThan(expandedEnd));
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, 1));
    expect(find.byType(TextField).hitTestable(), findsNothing);
    expect(find.byTooltip('展开搜索与筛选').hitTestable(), findsOneWidget);
    expect(requestedPages, ['1', '2']);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TextField).hitTestable(), findsNothing);
    expect(requestedPages, ['1', '2']);
    expect(tester.takeException(), isNull);
  });

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
