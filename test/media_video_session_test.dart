import 'dart:async';

import 'package:danbooru_viewer/media_video_session.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

class _ControlledVideo extends VideoPlayerController {
  _ControlledVideo(super.uri) : super.networkUrl();

  final initialized = Completer<void>();
  int disposeCalls = 0;
  int pauseCalls = 0;

  @override
  Future<void> initialize() => initialized.future;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rapid navigation serializes decoders and skips stale destinations',
    () async {
      final created = <_ControlledVideo>[];
      var live = 0;
      var maximumLive = 0;
      final session = MediaVideoSession(
        controllerFactory: (url) {
          live =
              created
                  .where((controller) => controller.disposeCalls == 0)
                  .length +
              1;
          if (live > maximumLive) maximumLive = live;
          final controller = _ControlledVideo(url);
          created.add(controller);
          return controller;
        },
      );
      final work = session.setSource('https://example.test/a.mp4');
      unawaited(session.setSource('https://example.test/b.mp4'));
      unawaited(session.setSource('https://example.test/c.mp4'));
      expect(created, hasLength(1));
      created.first.initialized.complete();
      await _flush();
      expect(created.map((video) => video.dataSource), [
        'https://example.test/a.mp4',
        'https://example.test/c.mp4',
      ]);
      expect(created.first.disposeCalls, 1);
      created.last.initialized.complete();
      await work;
      expect(session.controller, same(created.last));
      expect(maximumLive, 1);
      session.dispose();
      await _flush();
      expect(created.last.disposeCalls, 1);
    },
  );

  test(
    'changing source cancels a stalled download before creating the next decoder',
    () async {
      final tokens = <NetworkCancelToken>[];
      final next = _ControlledVideo(Uri.parse('https://example.test/b.mp4'));
      final session = MediaVideoSession(
        controllerLoader: (url, token) {
          tokens.add(token);
          if (url.endsWith('a.mp4')) {
            final stalled = Completer<VideoPlayerController>();
            token.addListener(
              () => stalled.completeError(const NetworkCancelledException()),
            );
            return stalled.future;
          }
          return Future.value(next);
        },
      );
      final work = session.setSource('https://example.test/a.mp4');
      unawaited(session.setSource('https://example.test/b.mp4'));
      await _flush();
      expect(tokens, hasLength(2));
      expect(tokens.first.isCancelled, isTrue);
      next.initialized.complete();
      await work;
      expect(session.controller, same(next));
      session.dispose();
    },
  );

  test(
    'returning to a pending video reuses it and never resumes itself',
    () async {
      final created = <_ControlledVideo>[];
      final session = MediaVideoSession(
        controllerFactory: (url) {
          final controller = _ControlledVideo(url);
          created.add(controller);
          return controller;
        },
      );
      final work = session.setSource('https://example.test/a.mp4');
      unawaited(session.setSource(null));
      unawaited(session.setSource('https://example.test/a.mp4'));
      created.single.initialized.complete();
      await work;
      expect(created, hasLength(1));
      expect(session.controller, same(created.single));
      expect(session.controller!.value.isPlaying, isFalse);
      session.pause();
      expect(created.single.pauseCalls, 1);
      await session.setSource(null);
      expect(created.single.disposeCalls, 1);
      expect(session.controller, isNull);
      session.dispose();
    },
  );

  test(
    'proxy change invalidates pending initialization even for the same URL',
    () async {
      final created = <_ControlledVideo>[];
      final session = MediaVideoSession(
        controllerFactory: (url) {
          final controller = _ControlledVideo(url);
          created.add(controller);
          return controller;
        },
      );
      final work = session.setSource('https://example.test/a.mp4');
      unawaited(session.setSource('https://example.test/a.mp4', revision: 1));
      created.single.initialized.complete();
      await _flush();
      expect(created, hasLength(2));
      expect(created.first.disposeCalls, 1);
      created.last.initialized.complete();
      await work;
      expect(session.controller, same(created.last));
      session.dispose();
    },
  );

  test(
    'dispose releases a late initializer once without notifying listeners',
    () async {
      final controller = _ControlledVideo(
        Uri.parse('https://example.test/a.mp4'),
      );
      final session = MediaVideoSession(controllerFactory: (_) => controller);
      var notifications = 0;
      session.addListener(() => notifications++);
      final work = session.setSource(controller.dataSource);
      session.dispose();
      final before = notifications;
      controller.initialized.complete();
      await work;
      expect(controller.disposeCalls, 1);
      expect(notifications, before);
    },
  );

  test(
    'a failed initializer can be retried without retaining its decoder',
    () async {
      final created = <_ControlledVideo>[];
      final session = MediaVideoSession(
        controllerFactory: (url) {
          final controller = _ControlledVideo(url);
          created.add(controller);
          return controller;
        },
      );
      final first = session.setSource('https://example.test/a.webm');
      created.single.initialized.completeError(StateError('unsupported codec'));
      await first;
      expect(session.error, isA<StateError>());
      expect(created.single.disposeCalls, 1);
      final retry = session.setSource('https://example.test/a.webm');
      created.last.initialized.complete();
      await retry;
      expect(session.error, isNull);
      expect(session.controller, same(created.last));
      session.dispose();
    },
  );
}
