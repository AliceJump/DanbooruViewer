import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'network/network_errors.dart';
import 'ugoira_codec.dart';

final _converter = NativeUgoiraConverter();

Future<Uint8List> convertUgoiraToGif(
  Future<Uint8List> Function() loadBytes, {
  NetworkCancelToken? cancelToken,
}) => _converter.convert(loadBytes, cancelToken: cancelToken);

Future<Uint8List> convertUgoiraBytesToGif(
  Uint8List bytes, {
  NetworkCancelToken? cancelToken,
}) => _converter.convertBytes(bytes, cancelToken: cancelToken);

Future<Uint8List> _encodeInIsolate(Uint8List bytes) =>
    compute(mergeUgoiraBytesToGifSync, bytes);

/// Native viewers queue the source reader, not a full ZIP per waiting tile.
/// Only one source is loaded and one compute isolate can run at a time. A
/// cancelled running isolate keeps its slot until compute actually completes.
class NativeUgoiraConverter {
  NativeUgoiraConverter({
    @visibleForTesting Future<Uint8List> Function(Uint8List)? encode,
    @visibleForTesting this.maxInputBytes = maxUgoiraZipBytes,
  }) : _encode = encode ?? _encodeInIsolate;

  final Future<Uint8List> Function(Uint8List) _encode;
  final int maxInputBytes;
  final Queue<_NativeConversion> _waiting = Queue();
  _NativeConversion? _active;

  /// Compatibility for already loaded bytes. Do not retain multiple large
  /// buffers while busy; application callers use the deferred [convert] path.
  Future<Uint8List> convertBytes(
    Uint8List bytes, {
    NetworkCancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    _checkSize(bytes);
    if (_active != null || _waiting.isNotEmpty) {
      throw const FormatException('动图转换忙碌，请稍后重试。');
    }
    return convert(() async => bytes, cancelToken: cancelToken);
  }

  /// The callback must defer download and reading until invoked. Waiting
  /// viewers therefore retain only their source descriptors and cancellation
  /// tokens, and a normal grid with more than four animations can finish.
  Future<Uint8List> convert(
    Future<Uint8List> Function() loadBytes, {
    NetworkCancelToken? cancelToken,
  }) async {
    final token = cancelToken ?? NetworkCancelToken();
    token.throwIfCancelled();
    final conversion = _NativeConversion(loadBytes, token);
    _waiting.add(conversion);
    conversion.removeCancelListener = token.addListener(() {
      if (_waiting.remove(conversion)) {
        conversion.loadBytes = null;
        conversion.removeCancelListener?.call();
        conversion.result.completeError(const NetworkCancelledException());
      }
    });
    _startNext();
    return conversion.result.future;
  }

  void _checkSize(Uint8List bytes) {
    if (bytes.length > maxInputBytes) {
      throw const FormatException('动图压缩包过大，请打开原链接查看。');
    }
  }

  void _startNext() {
    if (_active != null || _waiting.isEmpty) return;
    final conversion = _waiting.removeFirst();
    _active = conversion;
    unawaited(_run(conversion));
  }

  Future<void> _run(_NativeConversion conversion) async {
    try {
      conversion.cancelToken.throwIfCancelled();
      final loadBytes = conversion.loadBytes!;
      conversion.loadBytes = null;
      final bytes = await loadBytes();
      conversion.cancelToken.throwIfCancelled();
      _checkSize(bytes);
      final gif = await _encode(bytes);
      conversion.cancelToken.throwIfCancelled();
      conversion.result.complete(gif);
    } catch (error, stack) {
      conversion.result.completeError(
        conversion.cancelToken.isCancelled
            ? const NetworkCancelledException()
            : error,
        stack,
      );
    } finally {
      conversion.removeCancelListener?.call();
      _active = null;
      _startNext();
    }
  }
}

class _NativeConversion {
  _NativeConversion(this.loadBytes, this.cancelToken);

  Future<Uint8List> Function()? loadBytes;
  final NetworkCancelToken cancelToken;
  final Completer<Uint8List> result = Completer();
  void Function()? removeCancelListener;
}
