import 'dart:ui' as ui;

import 'package:danbooru_viewer/full_screen_image_page.dart';
import 'package:danbooru_viewer/media_image_frame.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:danbooru_viewer/post.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

class _FrameInfo extends Fake implements ui.FrameInfo {
  _FrameInfo(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 80);
}

class _LoopingCodec extends Fake implements ui.Codec {
  _LoopingCodec(this.image);
  final ui.Image image;
  int frameCalls = 0;
  int disposeCalls = 0;
  @override
  int get frameCount => 2;
  @override
  int get repetitionCount => -1;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    frameCalls++;
    return _FrameInfo(image.clone());
  }

  @override
  void dispose() => disposeCalls++;
}

class _AnimatedProvider extends ImageProvider<_AnimatedProvider> {
  _AnimatedProvider(this.codec);
  final _LoopingCodec codec;
  late final stream = MultiFrameImageStreamCompleter(
    codec: Future.value(codec),
    scale: 1,
  );
  int loads = 0;

  @override
  Future<_AnimatedProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _AnimatedProvider key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return stream;
  }
}

class _ManualCompleter extends ImageStreamCompleter {
  final _listeners = <ImageStreamListener>[];
  int get listenerCount => _listeners.length;
  int disposals = 0;

  void deliver(ui.Image image) => setImage(ImageInfo(image: image.clone()));
  void fail() => reportError(
    exception: const FormatException('Invalid image data'),
    silent: true,
  );

  @override
  void addListener(ImageStreamListener listener) {
    _listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    _listeners.remove(listener);
    super.removeListener(listener);
  }

  @override
  void onDisposed() {
    disposals++;
    super.onDisposed();
  }
}

class _ManualProvider extends ImageProvider<_ManualProvider> {
  final stream = _ManualCompleter();
  int loads = 0;

  @override
  Future<_ManualProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ManualProvider key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return stream;
  }
}

Future<void> _tick(WidgetTester tester, [int count = 5]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<double> _photoTransform(WidgetTester tester) => tester
    .widgetList<Transform>(
      find.descendant(
        of: find.byType(PhotoView),
        matching: find.byType(Transform),
      ),
    )
    .singleWhere((transform) => transform.child is CustomSingleChildLayout)
    .transform
    .storage
    .toList();

void main() {
  late ui.Image image;
  late int cacheSize;
  setUp(() async {
    image = await createTestImage(width: 3, height: 2);
    cacheSize = PaintingBinding.instance.imageCache.maximumSize;
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    PaintingBinding.instance.imageCache.maximumSize = cacheSize;
    image.dispose();
  });

  for (final fullScreen in [false, true]) {
    for (final initiallyVisible in [true, false]) {
      testWidgets(
        '${fullScreen ? 'full screen' : 'cached image'} stops hidden GIF decoding and retains its first frame (initially visible: $initiallyVisible)',
        (tester) async {
          // Handoff must not rely on the image fitting in the global LRU.
          PaintingBinding.instance.imageCache.maximumSize = 0;
          final visible = ValueNotifier(initiallyVisible);
          addTearDown(visible.dispose);
          final codec = _LoopingCodec(image);
          final provider = _AnimatedProvider(codec);
          Future<ImageProvider> load(String _) async => provider;
          final media = fullScreen
              ? FullScreenImagePage(
                  previewUrl: '',
                  highResUrl: 'https://example.test/loop.gif',
                  heroTag: 'loop',
                  imageProviderLoader: load,
                )
              : Scaffold(
                  body: CachedMediaImage(
                    imageUrl: 'https://example.test/loop.gif',
                    fit: BoxFit.contain,
                    imageProviderLoader: load,
                  ),
                );
          await tester.pumpWidget(
            MaterialApp(
              home: ValueListenableBuilder<bool>(
                valueListenable: visible,
                child: media,
                builder: (_, enabled, child) =>
                    TickerMode(enabled: enabled, child: child!),
              ),
            ),
          );
          await _tick(tester);
          if (initiallyVisible) {
            expect(codec.frameCalls, greaterThan(1));
            expect(
              tester.widget<RawImage>(find.byType(RawImage)).image!.width,
              3,
            );
            visible.value = false;
            await _tick(tester, 2);
          }
          final hiddenCalls = codec.frameCalls;
          await _tick(tester);
          expect(codec.frameCalls, hiddenCalls);
          expect(codec.disposeCalls, 0);
          visible.value = true;
          await _tick(tester);
          expect(codec.frameCalls, greaterThan(hiddenCalls));
          expect(provider.loads, 1);
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image!.width,
            3,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(codec.disposeCalls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('full screen restores its actual zoom and pan after hiding', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final source = _ManualProvider();
    source.stream.deliver(image);
    const url = 'https://example.test/shared.png';
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          child: FullScreenImagePage(
            previewUrl: '',
            heroTag: 'zoom',
            posts: [
              Post(id: 1, rating: 'g', tagString: '', fileUrl: url),
              Post(id: 2, rating: 'g', tagString: '', fileUrl: url),
            ],
            imageProviderLoader: (_) async => source,
          ),
          builder: (_, enabled, child) =>
              TickerMode(enabled: enabled, child: child!),
        ),
      ),
    );
    await _tick(tester);
    final initial = tester.getRect(find.byType(RawImage));
    var photo = tester.widget<PhotoView>(find.byType(PhotoView));
    photo.controller!.updateMultiple(
      scale: photo.controller!.scale! * 2,
      position: const Offset(55, -35),
    );
    await _tick(tester, 2);
    final zoomed = tester.getRect(find.byType(RawImage));
    final transform = _photoTransform(tester);
    expect(zoomed.width, closeTo(initial.width * 2, 0.001));
    expect(transform[12], 55);
    expect(transform[13], -35);

    for (var i = 0; i < 2; i++) {
      final oldController = photo.controller!;
      final oldScaleController = photo.scaleStateController!;
      var closedControllers = 0;
      oldController.outputStateStream.listen(
        (_) {},
        onDone: () => closedControllers++,
      );
      oldScaleController.outputScaleStateStream.listen(
        (_) {},
        onDone: () => closedControllers++,
      );
      visible.value = false;
      await _tick(tester, 2);
      expect(find.byType(PhotoView), findsNothing);
      expect(closedControllers, 2);
      visible.value = true;
      await _tick(tester, 2);
      photo = tester.widget<PhotoView>(find.byType(PhotoView));
      expect(photo.controller, isNot(same(oldController)));
      expect(photo.scaleStateController, isNot(same(oldScaleController)));
      expect(tester.getRect(find.byType(RawImage)), zoomed);
      expect(_photoTransform(tester), transform);
    }
    expect(source.loads, 1);

    // A different post resets the view, even when it has the same media URL.
    await tester.tap(find.byTooltip('下一张 (→)'));
    await _tick(tester);
    expect(find.text('#2'), findsOneWidget);
    expect(tester.getRect(find.byType(RawImage)), initial);
    expect(_photoTransform(tester)[12], 0);
    expect(_photoTransform(tester)[13], 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('an original arriving while hidden resets preview zoom', (
    tester,
  ) async {
    final originalImage = (await tester.runAsync(
      () => createTestImage(width: 30, height: 20),
    ))!;
    addTearDown(originalImage.dispose);
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final preview = _ManualProvider();
    preview.stream.deliver(image);
    final original = _ManualProvider();
    const originalUrl = 'https://example.test/original.png';
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          child: FullScreenImagePage(
            previewUrl: 'https://example.test/preview.png',
            highResUrl: originalUrl,
            heroTag: 'preview',
            imageProviderLoader: (url) async =>
                url == originalUrl ? original : preview,
          ),
          builder: (_, enabled, child) =>
              TickerMode(enabled: enabled, child: child!),
        ),
      ),
    );
    await _tick(tester);
    final initial = tester.getRect(find.byType(RawImage));
    final photo = tester.widget<PhotoView>(find.byType(PhotoView));
    photo.controller!.updateMultiple(
      scale: photo.controller!.scale! * 2,
      position: const Offset(55, -35),
    );
    await _tick(tester, 2);
    visible.value = false;
    await _tick(tester, 2);
    original.stream.deliver(originalImage);
    await _tick(tester, 2);
    expect(find.byType(PhotoView), findsNothing);
    visible.value = true;
    await _tick(tester, 2);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 30);
    expect(
      tester.getRect(find.byType(RawImage)),
      rectMoreOrLessEquals(initial, epsilon: 0.001),
    );
    expect(_photoTransform(tester)[12], 0);
    expect(_photoTransform(tester)[13], 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('synchronous first frames survive handoff without an LRU entry', (
    tester,
  ) async {
    PaintingBinding.instance.imageCache.maximumSize = 0;
    final source = _ManualProvider();
    source.stream.deliver(image);
    final frame = MediaImageFrame(source);
    expect(await frame.ready, isTrue);
    frame.handoff();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.stream.listenerCount, 0, reason: source.stream.toString());
    expect(source.stream.disposals, 0);
    await tester.pumpWidget(MaterialApp(home: Image(image: frame.provider)));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 3);
    expect(source.loads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    frame.dispose();
    frame.dispose();
    await tester.pump();
    expect(source.stream.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first-frame errors remove preload and pending cache listeners', (
    tester,
  ) async {
    final source = _ManualProvider();
    final frame = MediaImageFrame(source);
    source.stream.fail();
    expect(await frame.ready, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    frame.dispose();
    expect(source.stream.listenerCount, 0);
    expect(source.stream.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled first frame handles a late decoder error', (
    tester,
  ) async {
    final source = _ManualProvider();
    final frame = MediaImageFrame(source);
    frame.dispose();
    expect(await frame.ready, isFalse);
    source.stream.fail();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.stream.listenerCount, 0);
    expect(source.stream.disposals, 1);
    expect(tester.takeException(), isNull);
  });
}
