import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'media_utils.dart';
import 'network/app_network_service.dart';

/// Keeps one decoder alive, including while initialization is pending.
/// Navigation only replaces the desired source; stale work is disposed before
/// another controller is created and can never resume itself after navigation.
class MediaVideoSession extends ChangeNotifier {
  MediaVideoSession({this.controllerFactory, this.controllerLoader});

  final VideoPlayerController Function(Uri)? controllerFactory;
  final Future<VideoPlayerController> Function(String, NetworkCancelToken)?
  controllerLoader;
  NetworkCancelToken? _downloadCancel;
  VideoPlayerController? _controller;
  String? _loadedUrl;
  int? _loadedRevision;
  String? _requestedUrl;
  int _requestedRevision = 0;
  bool _disposed = false;
  bool _running = false;
  Future<void>? _work;
  Object? _error;

  VideoPlayerController? get controller =>
      _loadedUrl == _requestedUrl && _loadedRevision == _requestedRevision
      ? _controller
      : null;
  Object? get error => _error;
  bool get isLoading =>
      _requestedUrl != null && controller == null && _error == null;

  Future<void> setSource(String? url, {int revision = 0}) {
    if (_disposed) return Future<void>.value();
    if (_requestedUrl == url &&
        _requestedRevision == revision &&
        (_running || controller != null)) {
      return _work ?? Future<void>.value();
    }
    pause();
    _downloadCancel?.cancel();
    _requestedUrl = url;
    _requestedRevision = revision;
    _error = null;
    _notify();
    if (!_running) _work = _drain();
    return _work ?? Future<void>.value();
  }

  void pause() {
    final controller = _controller;
    if (controller == null) return;
    unawaited(controller.pause().catchError((Object _) {}));
  }

  bool _wanted(String? url, int revision) =>
      !_disposed && _requestedUrl == url && _requestedRevision == revision;

  Future<void> _disposeController(VideoPlayerController? controller) async {
    if (controller == null) return;
    try {
      // A platform create failure can leave the plugin waiting forever for its
      // creation completer. Keep cleanup running, but do not let that wait (or
      // a stalled platform dispose) prevent retrying or opening another video.
      await controller.dispose().timeout(const Duration(seconds: 2));
    } on Object {
      // The original dispose Future still owns any late platform cleanup.
      // Never retry disposal or resurrect this controller.
    }
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (!_disposed) {
        final url = _requestedUrl;
        final revision = _requestedRevision;
        if (_controller != null &&
            (_loadedUrl != url || _loadedRevision != revision)) {
          final previous = _controller;
          _controller = null;
          _loadedUrl = null;
          await _disposeController(previous);
          if (!_wanted(url, revision)) continue;
        }
        if (url == null || controller != null) break;

        VideoPlayerController? pending;
        NetworkCancelToken? downloadCancel;
        try {
          final factory = controllerFactory;
          if (factory != null) {
            pending = factory(Uri.parse(url));
          } else {
            downloadCancel = NetworkCancelToken();
            _downloadCancel = downloadCancel;
            pending =
                await (controllerLoader?.call(url, downloadCancel) ??
                    cachedVideoController(url, cancelToken: downloadCancel));
            if (identical(_downloadCancel, downloadCancel)) {
              _downloadCancel = null;
            }
          }
          if (!_wanted(url, revision)) continue;
          await pending.initialize().timeout(const Duration(seconds: 12));
          if (!_wanted(url, revision)) continue;
          _controller = pending;
          _loadedUrl = url;
          _loadedRevision = revision;
          pending = null;
          _notify();
        } catch (error) {
          if (_wanted(url, revision) && downloadCancel?.isCancelled != true) {
            _error = error;
            _notify();
          }
        } finally {
          if (identical(_downloadCancel, downloadCancel)) {
            _downloadCancel = null;
          }
          await _disposeController(pending);
        }
        if (_wanted(url, revision) && downloadCancel?.isCancelled != true) {
          break;
        }
      }
    } finally {
      _running = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _downloadCancel?.cancel();
    _requestedUrl = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(_disposeController(controller));
    super.dispose();
  }
}
