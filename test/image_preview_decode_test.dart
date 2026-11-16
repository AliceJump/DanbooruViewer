import 'dart:async';
import 'dart:ui' as ui;

import 'package:danbooru_viewer/full_screen_image_page.dart';
import 'package:danbooru_viewer/media_image_frame.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlledImage extends ImageProvider<_ControlledImage> {
  final _frame = Completer<ImageInfo>();

  void deliver(ui.Image image) =>
      _frame.complete(ImageInfo(image: image.clone()));
  void fail() =>
      _frame.completeError(const FormatException('Invalid image data'));

  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ControlledImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_frame.future);
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
  const previewUrl = 'https://example.test/preview.png';
  const originalUrl = 'https://example.test/original.png';
  late ui.Image previewImage;
  late ui.Image originalImage;

  setUp(() async {
    previewImage = await createTestImage(width: 12, height: 8);
    originalImage = await createTestImage(width: 48, height: 32);
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    previewImage.dispose();
    originalImage.dispose();
  });

  for (final fullScreen in [false, true]) {
    testWidgets(
      '${fullScreen ? 'full screen' : 'cached image'} retains a decoded preview until the original first frame and after decode errors',
      (tester) async {
        final preview = _ControlledImage();
        final corruptOriginal = _ControlledImage();
        final repairedOriginal = _ControlledImage();
        var originalLoads = 0;
        Future<ImageProvider> load(String url) async {
          if (url == previewUrl) return preview;
          expect(url, originalUrl);
          originalLoads++;
          return originalLoads == 1 ? corruptOriginal : repairedOriginal;
        }

        await tester.pumpWidget(
          MaterialApp(
            home: fullScreen
                ? FullScreenImagePage(
                    previewUrl: previewUrl,
                    highResUrl: originalUrl,
                    heroTag: 'decode-test',
                    imageProviderLoader: load,
                  )
                : Scaffold(
                    body: SizedBox(
                      width: 300,
                      height: 300,
                      child: CachedMediaImage(
                        imageUrl: originalUrl,
                        previewUrl: previewUrl,
                        fit: BoxFit.contain,
                        imageProviderLoader: load,
                      ),
                    ),
                  ),
          ),
        );
        preview.deliver(previewImage);
        await _pumpFrames(tester);
        // The original provider Future has completed, but its decoder has not.
        expect(originalLoads, 1);
        expect(_visibleWidths(tester), contains(12));
        expect(_visibleWidths(tester), isNot(contains(48)));
        corruptOriginal.fail();
        await _pumpFrames(tester);
        expect(_visibleWidths(tester), contains(12));
        final retry = find.text(fullScreen ? '重试原图' : '原图加载失败，重试');
        expect(retry, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(retry);
        await _pumpFrames(tester);
        expect(originalLoads, 2);
        expect(_visibleWidths(tester), contains(12));
        repairedOriginal.deliver(originalImage);
        await _pumpFrames(tester);
        expect(_visibleWidths(tester), contains(48));
        expect(_visibleWidths(tester), isNot(contains(12)));
        expect(retry, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('a late preview cannot replace a decoded full-screen original', (
    tester,
  ) async {
    final preview = _ControlledImage();
    final original = _ControlledImage();
    await tester.pumpWidget(
      MaterialApp(
        home: FullScreenImagePage(
          previewUrl: previewUrl,
          highResUrl: originalUrl,
          heroTag: 'decode-race',
          imageProviderLoader: (url) async =>
              url == previewUrl ? preview : original,
        ),
      ),
    );
    original.deliver(originalImage);
    await _pumpFrames(tester);
    expect(_visibleWidths(tester), contains(48));
    preview.deliver(previewImage);
    await _pumpFrames(tester);
    expect(_visibleWidths(tester), contains(48));
    expect(_visibleWidths(tester), isNot(contains(12)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposing a pending decoder cancels its first-frame wait', (
    tester,
  ) async {
    final provider = _ControlledImage();
    final frame = MediaImageFrame(provider);
    var finished = false;
    final pending = frame.ready.then((decoded) {
      expect(decoded, isFalse);
      finished = true;
    });
    frame.dispose();
    await pending;
    expect(finished, isTrue);
    provider.deliver(originalImage);
    await _pumpFrames(tester);
    expect(tester.takeException(), isNull);
  });
}
