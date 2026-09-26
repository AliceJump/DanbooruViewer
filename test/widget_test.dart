import 'dart:async';
import 'dart:convert';

import 'package:danbooru_viewer/media_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:danbooru_viewer/main.dart';

void main() {
  testWidgets('shows search UI', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Danbooru Viewer'), findsOneWidget);
    expect(find.bySemanticsLabel('搜索...'), findsOneWidget);
  });

  testWidgets('a newer search wins when requests finish out of order', (
    tester,
  ) async {
    final pending = <Completer<http.Response>>[];
    final requests = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MyHomePage(
          title: 'test',
          fetchPosts: (uri) {
            requests.add(uri);
            final response = Completer<http.Response>();
            pending.add(response);
            return response.future;
          },
        ),
      ),
    );

    expect(pending, hasLength(1));
    await tester.tap(find.text('全年龄 (R-0)'));
    await tester.pump();
    expect(pending, hasLength(2));
    expect(requests.last.queryParameters['tags'], 'rating:g');

    pending[1].complete(
      http.Response(
        jsonEncode([
          {'id': 2, 'rating': 'g', 'tag_string': 'new'},
        ]),
        200,
      ),
    );
    await tester.pump();
    expect(
      tester.widget<PostThumbnailTile>(find.byType(PostThumbnailTile)).heroTag,
      'post_2',
    );

    pending[0].complete(
      http.Response(
        jsonEncode([
          {'id': 1, 'rating': 'g', 'tag_string': 'old'},
        ]),
        200,
      ),
    );
    await tester.pump();
    expect(
      tester.widget<PostThumbnailTile>(find.byType(PostThumbnailTile)).heroTag,
      'post_2',
    );
  });

  testWidgets('search encodes special tag characters', (tester) async {
    final requests = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MyHomePage(
          title: 'test',
          fetchPosts: (uri) async {
            requests.add(uri);
            return http.Response('[]', 200);
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'foo&bar');
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    expect(requests.last.queryParameters['tags'], 'foo&bar');
  });

  testWidgets('reaching an empty page stops further pagination', (
    tester,
  ) async {
    final requests = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MyHomePage(
          title: 'test',
          fetchPosts: (uri) async {
            requests.add(uri);
            if (uri.queryParameters['page'] == '1') {
              return http.Response(
                jsonEncode([
                  for (var id = 1; id <= 100; id++)
                    {'id': id, 'rating': 'g', 'tag_string': ''},
                ]),
                200,
              );
            }
            return http.Response('[]', 200);
          },
        ),
      ),
    );
    await tester.pump();

    await tester.drag(find.byType(GridView), const Offset(0, -20000));
    await tester.pump();
    expect(requests.map((uri) => uri.queryParameters['page']), ['1', '2']);

    await tester.drag(find.byType(GridView), const Offset(0, 400));
    await tester.pump();
    await tester.drag(find.byType(GridView), const Offset(0, -400));
    await tester.pump();
    expect(requests, hasLength(2));
  });

  testWidgets('late response after disposal does not update state', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    await tester.pumpWidget(
      MaterialApp(
        home: MyHomePage(title: 'test', fetchPosts: (_) => pending.future),
      ),
    );

    await tester.pumpWidget(const SizedBox());
    pending.complete(http.Response('[]', 200));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
