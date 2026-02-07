import 'package:flutter/services.dart';

class DragHelper {
  static const _channel =
  MethodChannel('com.alicejump.danbooru_viewer/drag');

  static Future<void> startDrag(String path, {String type = 'image'}) async {
    await _channel.invokeMethod("startDrag", {
      "path": path,
      "type": type,
    });
  }
}
