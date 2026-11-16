import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'media_save_platform_io.dart'
    if (dart.library.js_interop) 'media_save_platform_web.dart'
    as platform;
import 'media_save_types.dart';
import 'media_types.dart';
import 'network/app_cache_manager.dart';
import 'network/app_network_service.dart';
import 'ugoira_conversion.dart';
import 'ugoira_utils.dart';

export 'media_save_types.dart' show MediaSaveResult, MediaSaveException;

@visibleForTesting
MediaSaveInput mediaSaveInputFromHttp(
  http.StreamedResponse response, {
  bool browserManaged = kIsWeb,
}) {
  final encoding = response.headers['content-encoding'];
  // Fetch returns decoded bytes, but CORS can hide Content-Encoding while
  // exposing the compressed Content-Length. A missing encoding header is
  // therefore not evidence of an uncompressed body in a browser.
  final length = !browserManaged && (encoding == null || encoding == 'identity')
      ? response.contentLength
      : null;
  return MediaSaveInput(response.stream, length: length);
}

String formatMediaSaveError(Object error) {
  if (error is MediaSaveException) return error.message;
  if (error is NetworkException) return networkErrorMessage(error);
  if (error is FormatException) return error.message;
  return '保存失败，请检查媒体格式、系统权限和剩余空间后重试。';
}

@visibleForTesting
String mediaSaveFileName(String source, {int? postId}) {
  final uri = Uri.tryParse(source);
  final path = uri?.path ?? source;
  var name = path.replaceAll('\\', '/').split('/').last;
  name = name.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  if (name.isEmpty || name == '.' || name == '..') name = 'media';
  if (name.length > 100) name = name.substring(name.length - 100);
  if (isUgoiraUrl(source)) name = '${name.substring(0, name.length - 4)}.gif';
  return 'danbooru_${postId == null ? '' : '${postId}_'}$name';
}

@visibleForTesting
Future<MediaSaveInput> convertUgoiraForSave(
  Future<MediaSaveInput> Function() openInput, {
  NetworkCancelToken? cancelToken,
  void Function(int received, int? total)? onProgress,
}) async {
  final gif = await convertUgoiraToGif(() async {
    final input = await openInput();
    return readBoundedUgoiraZipBytes(
      input.stream,
      cancelToken: cancelToken,
      total: input.length,
      onProgress: onProgress,
    );
  }, cancelToken: cancelToken);
  cancelToken?.throwIfCancelled();
  return MediaSaveInput(Stream.value(gif), length: gif.length);
}

Future<MediaSaveResult> saveMediaResource(
  String source, {
  int? postId,
  NetworkCancelToken? cancelToken,
  void Function(int received, int? total)? onProgress,
}) async {
  cancelToken?.throwIfCancelled();
  final uri = remoteMediaUri(source);
  // Sources with a scheme are never interpreted as trusted local paths.
  final parsed = Uri.tryParse(source);
  if (source.trim().isEmpty ||
      (uri == null &&
          parsed != null &&
          parsed.hasScheme &&
          !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(source))) {
    throw const MediaSaveException('媒体地址无效，仅支持 HTTP、HTTPS 或已有的本地文件。');
  }

  Future<MediaSaveInput> convertUgoira(
    Future<MediaSaveInput> Function() openInput,
  ) async {
    return convertUgoiraForSave(
      openInput,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  Future<MediaSaveInput> openSource() async {
    cancelToken?.throwIfCancelled();
    if (uri == null) {
      return isUgoiraUrl(source)
          ? convertUgoira(() => platform.openLocalMedia(source))
          : platform.openLocalMedia(source);
    }
    final cached = isUgoiraUrl(source)
        ? await getCachedUgoiraGifFile(source)
        : (await AppCacheManager.instance.getFileFromCache(source))?.file;
    cancelToken?.throwIfCancelled();
    if (cached != null && await cached.exists() && await cached.length() > 0) {
      return MediaSaveInput(cached.openRead(), length: await cached.length());
    }
    Future<MediaSaveInput> openRemote() async {
      final response = await AppNetworkService.instance.stream(
        uri,
        cancelToken: cancelToken,
        timeout: const Duration(minutes: 10),
      );
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw NetworkException(
          NetworkErrorKind.http,
          '媒体服务器返回 HTTP ${response.statusCode}，请稍后重试。',
          statusCode: response.statusCode,
        );
      }
      return mediaSaveInputFromHttp(response);
    }

    return isUgoiraUrl(source) ? convertUgoira(openRemote) : openRemote();
  }

  return platform.saveMediaToPlatform(
    fileName: mediaSaveFileName(source, postId: postId),
    isVideo: isVideoUrl(source),
    openSource: openSource,
    cancelToken: cancelToken,
    onProgress: onProgress,
  );
}
