import 'package:flutter/services.dart';

class DragHelper {
  static const _channel = MethodChannel('com.alicejump.danbooru_viewer/drag');

  static Future<bool> startDrag(String path, {String type = 'image'}) async {
    return await _channel.invokeMethod<bool>("startDrag", {
          "path": path,
          "type": type,
        }) ??
        false;
  }
}
