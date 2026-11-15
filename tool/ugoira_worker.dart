import 'dart:js_interop';

import 'package:danbooru_viewer/ugoira_codec.dart';
import 'package:danbooru_viewer/ugoira_worker_protocol.dart';
import 'package:web/web.dart' as web;

@JS('self')
external web.DedicatedWorkerGlobalScope get _scope;

void main() {
  _scope.onmessage = ((web.MessageEvent event) {
    try {
      final bytes = (event.data as JSUint8Array).toDart;
      _scope.postMessage(UgoiraWorkerReply(kind: 'started'));
      final gif = UgoiraTransferBytes(mergeUgoiraBytesToGifSync(bytes).toJS);
      _scope.postMessage(
        UgoiraWorkerReply(kind: 'ok', bytes: gif),
        <JSAny>[gif.buffer].toJS,
      );
    } catch (error) {
      _scope.postMessage(
        UgoiraWorkerReply(
          kind: 'error',
          message: error is FormatException
              ? error.message
              : '动图转换失败，请检查文件格式后重试。',
        ),
      );
    }
  }).toJS;
}
