import 'dart:async';

import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/download_progress_dialog.dart';
import 'package:danbooru_viewer/media_save_service.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/post.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Post _post(int id) => Post(
  id: id,
  rating: 'g',
  tagString: 'landscape',
  fileUrl: 'https://example.test/$id.jpg',
);

Future<Completer<Set<int>?>> _open(
  WidgetTester tester,
  MediaSaver save, {
  List<Post>? posts,
  bool dark = false,
  double scale = 1,
}) async {
  final result = Completer<Set<int>?>();
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result.complete(
                await showDialog<Set<int>>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => DownloadProgressDialog(
                    posts: posts ?? [_post(1), _post(2)],
                    saveMedia: save,
                  ),
                ),
              );
            },
            child: const Text('开始'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('开始'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets(
    'retry preserves successes and returns only unfinished selections',
    (tester) async {
      final attempts = <int>[];
      var fail = true;
      final result = await _open(tester, (
        source, {
        postId,
        cancelToken,
        onProgress,
      }) async {
        attempts.add(postId!);
        if (postId == 2 && fail) throw const MediaSaveException('没有相册权限');
        return const MediaSaveResult(destination: '相册', isVideo: false);
      });
      expect(attempts, [1, 2]);
      expect(find.text('已保存 1 / 2 项'), findsOneWidget);
      expect(find.text('没有相册权限'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('重试未完成项'));
      await tester.pumpAndSettle();
      expect(attempts, [1, 2, 2]);
      expect(find.text('已保存 2 / 2 项'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(await result.future, isEmpty);
    },
  );

  testWidgets(
    'cancel aborts the active request and never starts remaining work',
    (tester) async {
      final active = Completer<MediaSaveResult>();
      final attempts = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadProgressDialog(
            posts: [_post(1), _post(2)],
            saveMedia: (source, {postId, cancelToken, onProgress}) {
              attempts.add(postId!);
              cancelToken!.addListener(
                () => active.completeError(const NetworkCancelledException()),
              );
              return active.future;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('取消下载'));
      await tester.pumpAndSettle();
      expect(attempts, [1]);
      expect(find.text('已保存 0 / 2 项'), findsOneWidget);
      expect(find.text('重试未完成项'), findsOneWidget);
      expect(find.text('#2 · 已取消'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a missing media address remains selected after closing', (
    tester,
  ) async {
    final result = await _open(
      tester,
      (source, {postId, cancelToken, onProgress}) async {
        return const MediaSaveResult(destination: 'Downloads', isVideo: false);
      },
      posts: [
        _post(1),
        Post(id: 3, rating: 'g', tagString: ''),
      ],
    );
    expect(find.text('作品没有可下载的媒体地址'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(await result.future, {3});
  });

  for (final dark in [false, true]) {
    testWidgets(
      'save results remain usable at 200 percent text in a short window, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _open(
          tester,
          (source, {postId, cancelToken, onProgress}) async {
            throw const MediaSaveException('保存失败，请检查系统权限后重试。');
          },
          dark: dark,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('完成').hitTestable(), findsOneWidget);
        expect(find.text('重试未完成项').hitTestable(), findsOneWidget);
      },
    );
  }
}
