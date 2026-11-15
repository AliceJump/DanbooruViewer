import 'package:danbooru_viewer/full_screen_image_page.dart';
import 'package:danbooru_viewer/post.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'full screen closes, pages with keyboard and fits short $brightness viewport',
      (tester) async {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = const Size(320, 300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final posts = [
          Post(id: 1, rating: 'g', tagString: ''),
          Post(id: 2, rating: 'g', tagString: ''),
        ];
        int? returnedIndex;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () async {
                      returnedIndex = await Navigator.push<int>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => FullScreenImagePage(
                            previewUrl: '',
                            heroTag: 'test',
                            posts: posts,
                          ),
                        ),
                      );
                    },
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('关闭全屏 (Esc)'), findsOneWidget);
        expect(find.text('1 / 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.text('#2'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('打开'), findsOneWidget);
        expect(returnedIndex, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
