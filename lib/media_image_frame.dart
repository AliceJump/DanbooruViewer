import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

typedef MediaImageProviderLoader = Future<ImageProvider> Function(String url);

/// Keeps a decoded stream alive until its visible image takes over or the
/// request is replaced. Constructing an ImageProvider alone does not decode it.
class MediaImageFrame {
  MediaImageFrame(this._source) {
    _stream = _source.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!_ready.isCompleted) {
          final completer = _stream.completer!;
          _keepAlive = completer.keepAlive();
          _retainedProvider = _RetainedImageProvider(completer);
          _ready.complete(true);
        }
      },
      onError: (Object error, StackTrace? stack) {
        this.error = error;
        if (!_ready.isCompleted) _ready.complete(false);
        _removeListener();
        _evictFailedImage();
      },
    );
    // A cached image can call the listener synchronously from addListener.
    _listening = true;
    _stream.addListener(_listener);
  }

  final ImageProvider _source;
  final _ready = Completer<bool>();
  late final ImageStream _stream;
  late final ImageStreamListener _listener;
  ImageStreamCompleterHandle? _keepAlive;
  ImageProvider? _retainedProvider;
  Object? error;
  bool _disposed = false;
  bool _listening = false;
  bool _handoffScheduled = false;

  /// Reuse the exact decoded stream even if it is too large for ImageCache or
  /// the cache is cleared between preloading and mounting the visible image.
  ImageProvider get provider => _retainedProvider ?? _source;

  /// False means decoding failed or the owner cancelled this pending request.
  Future<bool> get ready => _ready.future;

  /// Call while building the consumer. It can attach in this frame before the
  /// preload listener is removed; keepAlive preserves frames without advancing
  /// animation when the consumer is hidden by TickerMode.
  void handoff() {
    if (_disposed || _keepAlive == null || !_listening || _handoffScheduled) {
      return;
    }
    _handoffScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _removeListener();
    });
  }

  void _removeListener() {
    if (!_listening) return;
    _listening = false;
    _stream.removeListener(_listener);
  }

  void _evictFailedImage() {
    unawaited(_source.evict().catchError((Object _) => false));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_ready.isCompleted) {
      // A cancelled first decode may still fail. This error-only callback does
      // not keep the stream alive or drive animation.
      _stream.completer?.addEphemeralErrorListener((_, _) {
        _evictFailedImage();
      });
    }
    _removeListener();
    _keepAlive?.dispose();
    _keepAlive = null;
    if (!_ready.isCompleted) _ready.complete(false);
  }
}

class _RetainedImageProvider extends ImageProvider<_RetainedImageProvider> {
  _RetainedImageProvider(this._completer);

  final ImageStreamCompleter _completer;

  @override
  Future<_RetainedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _RetainedImageProvider key,
    ImageErrorListener handleError,
  ) {
    // The source provider already participates in ImageCache. Do not add a
    // second cache entry or start another decode for the retained stream.
    stream.setCompleter(_completer);
  }
}
