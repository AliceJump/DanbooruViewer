import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'network/network_errors.dart';
import 'ugoira_codec.dart' show maxUgoiraZipBytes;

typedef UgoiraConversionOperation =
    Future<Uint8List> Function(Uint8List bytes, NetworkCancelToken cancelToken);

/// One running conversion, with a bounded waiting list. A grid of animations
/// must not allocate one decoder and a full uncompressed archive per tile.
class UgoiraConversionQueue {
  UgoiraConversionQueue(
    this._operation, {
    this.maxTasks = 4,
    this.maxInputBytes = maxUgoiraZipBytes,
  });

  final UgoiraConversionOperation _operation;
  final int maxTasks;
  final int maxInputBytes;
  final Queue<_Conversion> _waiting = Queue();
  _Conversion? _active;
  int _inputBytes = 0;

  Future<Uint8List> convert(
    Uint8List bytes, {
    NetworkCancelToken? cancelToken,
  }) async {
    final token = cancelToken ?? NetworkCancelToken();
    token.throwIfCancelled();
    if (bytes.length > maxUgoiraZipBytes) {
      throw const FormatException('动图压缩包过大，请打开原链接查看。');
    }
    if (_waiting.length + (_active == null ? 0 : 1) >= maxTasks ||
        _inputBytes + bytes.length > maxInputBytes) {
      throw const FormatException('动图转换队列已满，请稍后重试。');
    }
    final conversion = _Conversion(bytes, token);
    _waiting.add(conversion);
    _inputBytes += bytes.length;
    conversion.removeCancelListener = token.addListener(() {
      if (_waiting.remove(conversion)) {
        _inputBytes -= bytes.length;
        conversion.removeCancelListener?.call();
        conversion.result.completeError(const NetworkCancelledException());
      }
      // The running worker owns its cancellation and must finish cleanup
      // before the next decoder starts.
    });
    _startNext();
    return conversion.result.future;
  }

  void _startNext() {
    if (_active != null || _waiting.isEmpty) return;
    final conversion = _waiting.removeFirst();
    _active = conversion;
    unawaited(_run(conversion));
  }

  Future<void> _run(_Conversion conversion) async {
    try {
      conversion.cancelToken.throwIfCancelled();
      final gif = await _operation(conversion.bytes, conversion.cancelToken);
      conversion.cancelToken.throwIfCancelled();
      conversion.result.complete(gif);
    } catch (error, stack) {
      conversion.result.completeError(error, stack);
    } finally {
      conversion.removeCancelListener?.call();
      _inputBytes -= conversion.bytes.length;
      _active = null;
      _startNext();
    }
  }
}

class _Conversion {
  _Conversion(this.bytes, this.cancelToken);

  final Uint8List bytes;
  final NetworkCancelToken cancelToken;
  final Completer<Uint8List> result = Completer();
  void Function()? removeCancelListener;
}
