import 'dart:async';

import 'package:danbooru_viewer/completion_service.dart';
import 'package:danbooru_viewer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/fake_completion_service.dart';

SearchCompletionSuggestion suggestion(String label, {String? insertValue}) {
  return SearchCompletionSuggestion(
    value: label,
    insertValue: insertValue ?? label,
    source: 'test',
    score: 100,
    category: 0,
  );
}

Future<void> pumpHome(
  WidgetTester tester,
  FakeCompletionService service, {
  List<Uri>? requests,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MyHomePage(
        title: 'test',
        completionService: service,
        fetchPosts: (uri) async {
          requests?.add(uri);
          return http.Response('[]', 200);
        },
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('manual search stays available while bootstrap is pending', (
    tester,
  ) async {
    final bootstrap = Completer<List<SearchCompletionSuggestion>>();
    final service = FakeCompletionService(onBootstrap: () => bootstrap.future);
    final requests = <Uri>[];
    await pumpHome(tester, service, requests: requests);

    await tester.enterText(find.byType(TextField), 'blue_hair');
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    expect(requests.last.queryParameters['tags'], 'blue_hair');
    expect(service.bootstrapCalls, 1);
    expect(service.queries, isEmpty);

    bootstrap.complete([suggestion('popular_tag')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('popular_tag'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(service.disposeCalls, 1);
  });

  testWidgets(
    'bootstrap errors survive refocus and stay separate from query errors',
    (tester) async {
      final pending = Completer<List<SearchCompletionSuggestion>>();
      final service = FakeCompletionService(
        onBootstrap: () async => throw StateError('bootstrap unavailable'),
        onSearch: (query) async {
          if (query == 'bad') throw StateError('query unavailable');
          return pending.future;
        },
      );
      await pumpHome(tester, service);
      final field = find.byType(TextField);
      final unavailable = find.text('标签建议暂不可用，仍可直接搜索');

      await tester.tap(field);
      await tester.pump();
      expect(unavailable, findsOneWidget);
      tester.widget<TextField>(field).focusNode!.unfocus();
      await tester.pump();
      expect(unavailable, findsNothing);
      await tester.tap(field);
      await tester.pump();
      expect(unavailable, findsOneWidget);

      await tester.enterText(field, 'bad');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(unavailable, findsOneWidget);
      await tester.enterText(field, 'blue');
      await tester.pump(const Duration(milliseconds: 120));
      expect(unavailable, findsNothing);
      expect(find.text('正在查找标签建议...'), findsOneWidget);
      pending.complete([suggestion('blue_hair')]);
      await tester.pump();
      await tester.pump();
      expect(find.text('blue_hair'), findsOneWidget);
      expect(unavailable, findsNothing);

      await tester.enterText(field, '');
      await tester.pump();
      expect(unavailable, findsOneWidget);
      expect(service.bootstrapCalls, 1);
      expect(service.queries, ['bad', 'blue']);
    },
  );

  testWidgets(
    'latest completion wins and the same token is not queried again',
    (tester) async {
      final first = Completer<List<SearchCompletionSuggestion>>();
      final second = Completer<List<SearchCompletionSuggestion>>();
      final service = FakeCompletionService(
        onSearch: (query) => query == 'a' ? first.future : second.future,
      );
      await pumpHome(tester, service);

      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump(const Duration(milliseconds: 120));
      expect(service.queries, ['a', 'ab']);

      second.complete([suggestion('abacus')]);
      await tester.pump();
      await tester.pump();
      expect(find.text('abacus'), findsOneWidget);
      first.complete([suggestion('apple')]);
      await tester.pump();
      await tester.pump();
      expect(find.text('abacus'), findsOneWidget);
      expect(find.text('apple'), findsNothing);

      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 1,
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(service.queries, ['a', 'ab']);
    },
  );

  testWidgets('a result arriving after blur does not reopen suggestions', (
    tester,
  ) async {
    final pending = Completer<List<SearchCompletionSuggestion>>();
    final service = FakeCompletionService(onSearch: (_) => pending.future);
    await pumpHome(tester, service);
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 120));

    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    await tester.pump();
    pending.complete([suggestion('apple')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('apple'), findsNothing);
    expect(find.text('正在查找标签建议...'), findsNothing);
  });

  testWidgets('selecting a suggestion invalidates a pending newer query', (
    tester,
  ) async {
    final pending = Completer<List<SearchCompletionSuggestion>>();
    final service = FakeCompletionService(
      onSearch: (query) async {
        if (query == 'a') return [suggestion('abacus')];
        return pending.future;
      },
    );
    final requests = <Uri>[];
    await pumpHome(tester, service, requests: requests);
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('abacus'));
    await tester.pump();
    expect(requests.last.queryParameters['tags'], 'abacus');

    pending.complete([suggestion('absolute')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('absolute'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.widgetWithText(InputChip, 'abacus'), findsOneWidget);
  });

  testWidgets(
    'pending bootstrap and search can finish after service disposal',
    (tester) async {
      final bootstrap = Completer<List<SearchCompletionSuggestion>>();
      final query = Completer<List<SearchCompletionSuggestion>>();
      final service = FakeCompletionService(
        onBootstrap: () => bootstrap.future,
        onSearch: (_) => query.future,
      );
      await pumpHome(tester, service);
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpWidget(const SizedBox());
      expect(service.disposeCalls, 1);

      bootstrap.complete([suggestion('popular')]);
      query.complete([suggestion('apple')]);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submitted tags get their Chinese label without delaying search',
    (tester) async {
      final lookup = Completer<Map<String, CompletionTagInfo>>();
      final service = FakeCompletionService(onLookup: (_) => lookup.future);
      final requests = <Uri>[];
      await pumpHome(tester, service, requests: requests);
      await tester.enterText(find.byType(TextField), 'blue_hair');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(requests.last.queryParameters['tags'], 'blue_hair');
      expect(find.widgetWithText(InputChip, 'blue_hair'), findsOneWidget);

      lookup.complete({
        'blue_hair': const CompletionTagInfo(label: '蓝发', category: 0),
      });
      await tester.pump();
      await tester.pump();
      expect(find.widgetWithText(InputChip, '蓝发'), findsOneWidget);
      expect(requests.last.queryParameters['tags'], 'blue_hair');
    },
  );
}
