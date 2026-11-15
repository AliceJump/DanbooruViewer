import 'dart:async';

import 'package:danbooru_viewer/media_utils.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _CachedMedia extends Fake implements CacheManager {
  _CachedMedia(this.file);
  final Future<File> file;
  final urls = <String>[];

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) {
    urls.add(url);
    return file;
  }
}

Future<BuildContext> _context(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold(body: SizedBox());
        },
      ),
    ),
  );
  return context;
}

void main() {
  const channel = MethodChannel('com.alicejump.danbooru_viewer/external_media');
  final calls = <MethodCall>[];
  late File file;
  bool opened = true;

  setUp(() {
    file = MemoryFileSystem().file('/cache/downloaded-without-extension');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([1, 2, 3]);
    calls.clear();
    opened = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return opened;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final media in {
    'MP4': 'video/mp4',
    'm4v': 'video/mp4',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
  }.entries) {
    testWidgets(
      'Android passes cached ${media.key} and MIME to FileProvider',
      (tester) async {
        final context = await _context(tester);
        final cache = _CachedMedia(Future.value(file));
        final url = 'https://example.test/video.${media.key}?signed=1';
        final open = openMediaExternally(context, url, cacheManager: cache);
        await tester.pump();
        await open;
        expect(cache.urls, [url]);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'openFile');
        expect(calls.single.arguments, {
          'path': file.path,
          'mimeType': media.value,
        });
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'missing external player is reported without opening the URL',
    (tester) async {
      opened = false;
      final context = await _context(tester);
      final cache = _CachedMedia(Future.value(file));
      final open = openMediaExternally(
        context,
        'https://example.test/video.webm',
        cacheManager: cache,
      );
      await tester.pump();
      await open;
      await tester.pump();
      expect(calls, hasLength(1));
      expect(find.text('没有找到能够打开此文件的外部播放器。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'leaving while downloading prevents launching another app',
    (tester) async {
      final context = await _context(tester);
      final pending = Completer<File>();
      final cache = _CachedMedia(pending.future);
      final open = openMediaExternally(
        context,
        'https://example.test/video.mp4',
        cacheManager: cache,
      );
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      pending.complete(file);
      await tester.pump();
      await open;
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
