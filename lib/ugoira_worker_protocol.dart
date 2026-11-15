import 'dart:js_interop';

extension type UgoiraTransferBytes(JSUint8Array value) implements JSUint8Array {
  external JSArrayBuffer get buffer;
}

extension type UgoiraWorkerReply._(JSObject _) implements JSObject {
  external factory UgoiraWorkerReply({
    required String kind,
    JSUint8Array? bytes,
    String? message,
  });

  external String get kind;
  external JSUint8Array? get bytes;
  external String? get message;
}
