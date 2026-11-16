import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:danbooru_viewer/full_screen_image_page.dart';
import 'package:danbooru_viewer/post.dart';
import 'package:danbooru_viewer/tag_blocklist.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackedCompleter extends OneFrameImageStreamCompleter {
  _TrackedCompleter(super.image);

  final _active = <ImageStreamListener>[];
  int get listenerCount => _active.length;

  @override
  void addListener(ImageStreamListener listener) {
    _active.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    _active.remove(listener);
    super.removeListener(listener);
  }
}

class _PendingImage extends ImageProvider<_PendingImage> {
  final _firstFrame = Completer<ImageInfo>();
  late final stream = _TrackedCompleter(_firstFrame.future);

  void deliver(ui.Image image) =>
      _firstFrame.complete(ImageInfo(image: image.clone()));

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImage key,
    ImageDecoderCallback decode,
  ) => stream;
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Iterable<int> _visibleWidths(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .map((widget) => widget.image?.width)
    .whereType<int>();

void main() {
  const source = 'https://example.test/shared.png';
  const preview = 'https://example.test/shared-preview.png';
  late ui.Image previewImage;
  late ui.Image originalImage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previewImage = await createTestImage(width: 12, height: 8);
    originalImage = await createTestImage(width: 48, height: 32);
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    previewImage.dispose();
    originalImage.dispose();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'hiding a pending image releases its listeners even when the next post shares its URLs',
    (tester) async {
      final store = TagBlocklist();
      await store.initialize();
      addTearDown(store.dispose);
      final oldOriginal = _PendingImage();
      final oldPreview = _PendingImage();
      final nextOriginal = _PendingImage();
      final nextPreview = _PendingImage();
      var originalLoads = 0;
      var previewLoads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FullScreenImagePage(
            previewUrl: preview,
            highResUrl: source,
            heroTag: 'post_41',
            posts: [
              for (final entry in {41: 'cat', 42: 'dog'}.entries)
                Post(
                  id: entry.key,
                  rating: 'g',
                  tagString: entry.value,
                  fileUrl: source,
                  previewFileUrl: preview,
                ),
            ],
            blocklist: store,
            imageProviderLoader: (url) async {
              if (url == source) {
                return ++originalLoads == 1 ? oldOriginal : nextOriginal;
              }
              return ++previewLoads == 1 ? oldPreview : nextPreview;
            },
          ),
        ),
      );
      await _pumpFrames(tester);
      final originalListeners = oldOriginal.stream.listenerCount;
      final previewListeners = oldPreview.stream.listenerCount;
      expect(originalListeners, greaterThan(0));
      expect(previewListeners, greaterThan(0));
      await store.addTags(['cat']);
      // Check before rendering another frame: hidden requests must already
      // have detached the page's first-frame listener.
      expect(oldOriginal.stream.listenerCount, originalListeners - 1);
      expect(oldPreview.stream.listenerCount, previewListeners - 1);
      oldOriginal.deliver(originalImage);
      oldPreview.deliver(previewImage);
      await _pumpFrames(tester);
      expect(find.text('#42'), findsOneWidget);
      expect(_visibleWidths(tester), isEmpty);
      expect(originalLoads, 2);
      expect(previewLoads, 2);
      nextPreview.deliver(previewImage);
      nextOriginal.deliver(originalImage);
      await _pumpFrames(tester);
      expect(_visibleWidths(tester), contains(48));
      await store.addTags(['dog']);
      await _pumpFrames(tester);
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      expect(_visibleWidths(tester), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'switching to uninitialized rules cancels a pending frame before the rule load completes',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      final initial = TagBlocklist();
      await initial.initialize();
      final gate = Completer<SharedPreferences>();
      final replacement = TagBlocklist(loadPreferences: () => gate.future);
      final active = ValueNotifier(initial);
      addTearDown(initial.dispose);
      addTearDown(replacement.dispose);
      addTearDown(active.dispose);
      final oldOriginal = _PendingImage();
      final restoredOriginal = _PendingImage();
      var loads = 0;
      final posts = [
        Post(id: 41, rating: 'g', tagString: 'cat', fileUrl: source),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<TagBlocklist>(
            valueListenable: active,
            builder: (context, store, _) => FullScreenImagePage(
              previewUrl: '',
              highResUrl: source,
              heroTag: 'post_41',
              posts: posts,
              blocklist: store,
              imageProviderLoader: (_) async =>
                  ++loads == 1 ? oldOriginal : restoredOriginal,
            ),
          ),
        ),
      );
      await _pumpFrames(tester);
      final before = oldOriginal.stream.listenerCount;
      active.value = replacement;
      await tester.pump();
      expect(replacement.loaded, isFalse);
      expect(oldOriginal.stream.listenerCount, before - 1);
      oldOriginal.deliver(originalImage);
      await _pumpFrames(tester);
      expect(_visibleWidths(tester), isEmpty);
      expect(loads, 1);
      await preferences.setString(
        TagBlocklist.storageKey,
        jsonEncode({
          'version': 1,
          'enabled': true,
          'tags': ['cat'],
        }),
      );
      gate.complete(preferences);
      await _pumpFrames(tester);
      expect(find.text('此列表中的作品都已被标签屏蔽'), findsOneWidget);
      await replacement.removeTags(['cat']);
      await _pumpFrames(tester);
      expect(loads, 2);
      restoredOriginal.deliver(originalImage);
      await _pumpFrames(tester);
      expect(find.text('#41'), findsOneWidget);
      expect(_visibleWidths(tester), contains(48));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
