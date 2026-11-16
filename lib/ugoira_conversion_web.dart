import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import 'network/network_errors.dart';
import 'ugoira_conversion_queue.dart';
import 'ugoira_worker_protocol.dart';

const ugoiraWorkerAsset = 'assets/ugoira_worker.js';
const _workerUnavailable = '动图后台转换组件无法加载，请刷新页面或检查站点资源与浏览器权限。';
final _converter = WebUgoiraConverter();

Future<Uint8List> convertUgoiraToGif(
  Future<Uint8List> Function() loadBytes, {
  NetworkCancelToken? cancelToken,
}) async {
  cancelToken?.throwIfCancelled();
  final bytes = await loadBytes();
  cancelToken?.throwIfCancelled();
  return _converter.convert(bytes, cancelToken: cancelToken);
}

Future<Uint8List> convertUgoiraBytesToGif(
  Uint8List bytes, {
  NetworkCancelToken? cancelToken,
}) => _converter.convert(bytes, cancelToken: cancelToken);

/// Uses the Flutter asset bundle rather than an absolute URL, so Pages base
/// paths and the browser test asset server resolve the identical worker file.
/// There is deliberately no synchronous fallback if loading or CSP fails.
class WebUgoiraConverter {
  WebUgoiraConverter({
    @visibleForTesting Future<String> Function()? loadScript,
    @visibleForTesting AssetBundle? assetBundle,
    @visibleForTesting this.onStarted,
    @visibleForTesting this.timeout = const Duration(seconds: 90),
  }) : _loadScript =
           loadScript ??
           (() => (assetBundle ?? rootBundle).loadString(
             ugoiraWorkerAsset,
             // CachingAssetBundle retains failed/pending string futures too.
             // A missing or stalled resource must be fetched again on retry.
             cache: false,
           )) {
    _queue = UgoiraConversionQueue(_runWorker);
  }

  final Future<String> Function() _loadScript;
  final void Function()? onStarted;
  final Duration timeout;
  late final UgoiraConversionQueue _queue;

  Future<Uint8List> convert(
    Uint8List bytes, {
    NetworkCancelToken? cancelToken,
  }) => _queue.convert(bytes, cancelToken: cancelToken);

  Future<Uint8List> _runWorker(
    Uint8List bytes,
    NetworkCancelToken token,
  ) async {
    token.throwIfCancelled();
    final result = Completer<Uint8List>();
    web.Worker? worker;
    String? objectUrl;
    void fail(Object error, [StackTrace? stack]) {
      if (!result.isCompleted) result.completeError(error, stack);
    }

    final timer = Timer(
      timeout,
      () => fail(const FormatException('动图转换超时，请重试或打开原链接查看。')),
    );
    final removeCancelListener = token.addListener(
      () => fail(const NetworkCancelledException()),
    );
    try {
      final String script;
      try {
        // Cancellation/timeout also releases the queue if fetching the worker
        // asset is still pending; a late load cannot create an orphan worker.
        script =
            await Future.any<Object>([_loadScript(), result.future]) as String;
      } catch (error) {
        if (result.isCompleted) rethrow;
        throw const FormatException(_workerUnavailable);
      }
      token.throwIfCancelled();
      if (script.isEmpty) throw const FormatException(_workerUnavailable);
      final blob = web.Blob(
        <JSAny>[script.toJS].toJS,
        web.BlobPropertyBag(type: 'text/javascript'),
      );
      objectUrl = web.URL.createObjectURL(blob);
      worker = web.Worker(objectUrl.toJS);
      worker.onmessage = ((web.MessageEvent event) {
        if (result.isCompleted) return;
        try {
          final reply = event.data as UgoiraWorkerReply;
          switch (reply.kind) {
            case 'started':
              onStarted?.call();
            case 'ok':
              final output = reply.bytes;
              if (output == null) {
                fail(const FormatException('动图后台转换返回了无效结果。'));
              } else {
                result.complete(output.toDart);
              }
            case 'error':
              fail(FormatException(reply.message ?? '动图转换失败，请检查文件格式后重试。'));
            default:
              fail(const FormatException('动图后台转换返回了无效结果。'));
          }
        } catch (error, stack) {
          fail(error, stack);
        }
      }).toJS;
      worker.onerror = ((web.Event event) {
        event.preventDefault();
        fail(const FormatException(_workerUnavailable));
      }).toJS;
      worker.onmessageerror = ((web.Event _) {
        fail(const FormatException('动图后台转换返回了无效结果。'));
      }).toJS;
      // The input may be shared with the memory cache. Transfer a private copy
      // so cancelling/terminating this worker cannot detach cached ZIP bytes.
      final transferred = UgoiraTransferBytes(Uint8List.fromList(bytes).toJS);
      worker.postMessage(transferred, <JSAny>[transferred.buffer].toJS);
      return await result.future;
    } on NetworkCancelledException {
      rethrow;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(_workerUnavailable);
    } finally {
      timer.cancel();
      removeCancelListener();
      worker?.onmessage = null;
      worker?.onmessageerror = null;
      worker?.onerror = null;
      worker?.terminate();
      if (objectUrl != null) web.URL.revokeObjectURL(objectUrl);
    }
  }
}
