// Browser downloads need a Blob; keep the buffer bounded for large media.
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

import 'media_save_types.dart';
import 'network/app_network_service.dart';

const _maxDownloadBytes = 128 * 1024 * 1024;

Future<MediaSaveInput> openLocalMedia(String source) async {
  throw const MediaSaveException('网页版无法读取本地缓存路径，请从作品的媒体地址重新保存。');
}

Future<MediaSaveResult> saveMediaToPlatform({
  required String fileName,
  required bool isVideo,
  required Future<MediaSaveInput> Function() openSource,
  NetworkCancelToken? cancelToken,
  void Function(int received, int? total)? onProgress,
}) async {
  cancelToken?.throwIfCancelled();
  final input = await openSource();
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in input.stream) {
    cancelToken?.throwIfCancelled();
    if (bytes.length + chunk.length > _maxDownloadBytes) {
      throw const MediaSaveException('文件超过网页版 128 MB 的保存上限，请用浏览器打开原链接下载。');
    }
    bytes.add(chunk);
    onProgress?.call(bytes.length, input.length);
  }
  cancelToken?.throwIfCancelled();
  if (bytes.isEmpty || (input.length != null && bytes.length != input.length)) {
    throw const MediaSaveException('媒体没有下载完整，请检查连接后重试。');
  }
  final blob = html.Blob([bytes.takeBytes()]);
  final objectUrl = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: objectUrl)..download = fileName;
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  // Let the browser consume the object URL before revoking it.
  Future<void>.delayed(const Duration(seconds: 30), () {
    html.Url.revokeObjectUrl(objectUrl);
  });
  return MediaSaveResult(destination: '已交给浏览器下载', isVideo: isVideo);
}
