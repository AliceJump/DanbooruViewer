import 'dart:async';

import 'package:flutter/painting.dart';

typedef MediaImageProviderLoader = Future<ImageProvider> Function(String url);

/// Keeps a decoded stream alive until its visible image takes over or the
/// request is replaced. Constructing an ImageProvider alone does not decode it.
class MediaImageFrame {
  MediaImageFrame(this.provider) {
    _stream = provider.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!_ready.isCompleted) _ready.complete(true);
      },
      onError: (Object error, StackTrace? stack) {
        this.error = error;
        if (!_ready.isCompleted) _ready.complete(false);
      },
    );
    _stream.addListener(_listener);
  }

  final ImageProvider provider;
  final _ready = Completer<bool>();
  late final ImageStream _stream;
  late final ImageStreamListener _listener;
  Object? error;
  bool _disposed = false;

  /// False means decoding failed or the owner cancelled this pending request.
  Future<bool> get ready => _ready.future;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stream.removeListener(_listener);
    if (!_ready.isCompleted) _ready.complete(false);
  }
}
