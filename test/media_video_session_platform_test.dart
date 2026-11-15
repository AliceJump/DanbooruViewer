import 'dart:async';

import 'package:danbooru_viewer/media_utils.dart';
import 'package:danbooru_viewer/media_video_session.dart';
import 'package:danbooru_viewer/post.dart';
import 'package:danbooru_viewer/post_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart' show VideoPlayerController;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _ObserverBinding extends AutomatedTestWidgetsFlutterBinding {
  final activeObservers = <WidgetsBindingObserver>{};

  @override
  void addObserver(WidgetsBindingObserver observer) {
    activeObservers.add(observer);
    super.addObserver(observer);
  }

  @override
  bool removeObserver(WidgetsBindingObserver observer) {
    activeObservers.remove(observer);
    return super.removeObserver(observer);
  }
}

class _VideoPlatform extends VideoPlayerPlatform {
  bool failNextCreation = false;
  int creations = 0;
  int pauseCalls = 0;
  int playCalls = 0;
  final disposed = <int>[];
  final completedDisposals = <int>[];
  final heldDisposals = <int, Completer<void>>{};
  final events = <int, StreamController<VideoEvent>>{};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    creations++;
    if (failNextCreation) {
      failNextCreation = false;
      throw PlatformException(code: 'create_failed', message: 'No decoder');
    }
    return creations;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final stream = StreamController<VideoEvent>();
    events[playerId] = stream;
    stream.onListen = () => stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 1),
        size: const Size(16, 16),
      ),
    );
    return stream.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await heldDisposals[playerId]?.future;
    await events.remove(playerId)?.close();
    completedDisposals.add(playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> pause(int playerId) async {
    pauseCalls++;
  }

  @override
  Future<void> play(int playerId) async {
    playCalls++;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

void main() {
  final binding = _ObserverBinding();

  for (final localFile in [false, true]) {
    test(
      'production ${localFile ? 'file' : 'network'} create failure leaves no observer and permits retry',
      () async {
        final previous = VideoPlayerPlatform.instance;
        final platform = _VideoPlatform()..failNextCreation = true;
        VideoPlayerPlatform.instance = platform;
        addTearDown(() => VideoPlayerPlatform.instance = previous);
        final session = MediaVideoSession(
          controllerFactory: (uri) => createMediaVideoController(
            localFile ? Uri.file('/cache${uri.path}') : uri,
          ),
        );
        addTearDown(session.dispose);
        final observersBefore = Set.of(binding.activeObservers);
        var finished = false;
        final first = session
            .setSource('https://example.test/a.mp4')
            .then((_) => finished = true);
        await Future<void>.delayed(Duration.zero);
        expect(session.error, isA<PlatformException>());
        expect(finished, isFalse);
        expect(binding.activeObservers, observersBefore);
        await first.timeout(const Duration(seconds: 3));
        expect(finished, isTrue);
        expect(platform.disposed, isEmpty);

        await session
            .setSource('https://example.test/a.mp4')
            .timeout(const Duration(seconds: 3));
        expect(platform.creations, 2);
        expect(session.controller, isNotNull);
        expect(
          session.controller!.videoPlayerOptions?.allowBackgroundPlayback,
          isTrue,
        );
        expect(session.error, isNull);
        final playerId = session.controller!.playerId;
        await session.setSource(null).timeout(const Duration(seconds: 3));
        expect(platform.disposed, [playerId]);
        expect(platform.completedDisposals, [playerId]);
        expect(binding.activeObservers, observersBefore);
      },
    );
  }

  for (final stalled in [false, true]) {
    test(
      stalled
          ? 'stalled platform disposal cannot block navigation or skip late cleanup'
          : 'created controllers finish normal disposal before the next decoder',
      () async {
        final previous = VideoPlayerPlatform.instance;
        final platform = _VideoPlatform();
        VideoPlayerPlatform.instance = platform;
        addTearDown(() => VideoPlayerPlatform.instance = previous);
        final session = MediaVideoSession(
          controllerFactory: createMediaVideoController,
        );
        addTearDown(session.dispose);
        await session
            .setSource('https://example.test/a.mp4')
            .timeout(const Duration(seconds: 3));
        final firstId = session.controller!.playerId;
        final disposal = Completer<void>();
        platform.heldDisposals[firstId] = disposal;
        var finished = false;
        final next = session
            .setSource('https://example.test/b.mp4')
            .then((_) => finished = true);
        await Future<void>.delayed(Duration.zero);
        expect(platform.disposed, [firstId]);
        expect(platform.creations, 1);
        expect(finished, isFalse);
        if (stalled) {
          await next.timeout(const Duration(seconds: 3));
          expect(finished, isTrue);
          expect(platform.completedDisposals, isEmpty);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(platform.creations, 1);
        }
        disposal.complete();
        await next.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(Duration.zero);
        expect(platform.creations, 2);
        expect(platform.completedDisposals, [firstId]);
        expect(session.controller?.dataSource, 'https://example.test/b.mp4');
        final secondId = session.controller!.playerId;
        await session.setSource(null).timeout(const Duration(seconds: 3));
        expect(platform.disposed, [firstId, secondId]);
        expect(platform.completedDisposals, [firstId, secondId]);
      },
    );
  }

  testWidgets(
    'page-owned lifecycle pauses and never resumes the real controller',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final previous = VideoPlayerPlatform.instance;
      final platform = _VideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      late VideoPlayerController controller;
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            posts: [
              Post(
                id: 42,
                rating: 'g',
                tagString: '',
                fileUrl: 'https://example.test/a.mp4',
              ),
            ],
            initialIndex: 0,
            completionDisplayByValue: const {},
            videoControllerFactory: (uri) {
              controller = createMediaVideoController(uri);
              return controller;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.value.isInitialized, isTrue);
      expect(controller.value.isPlaying, isFalse);
      expect(platform.playCalls, 0);
      await controller.play();
      expect(controller.value.isPlaying, isTrue);
      final pausesBefore = platform.pauseCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.value.isPlaying, isFalse);
      expect(platform.pauseCalls, greaterThan(pausesBefore));
      final playsBefore = platform.playCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(controller.value.isPlaying, isFalse);
      expect(platform.playCalls, playsBefore);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    },
  );
}
