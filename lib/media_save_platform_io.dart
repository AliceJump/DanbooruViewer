import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'media_save_types.dart';
import 'network/app_network_service.dart';

int _saveSequence = 0;

Future<MediaSaveInput> openLocalMedia(String source) async {
  final file = File(source);
  if (!await file.exists()) {
    throw const MediaSaveException('本地媒体文件已不存在，请重新加载后保存。');
  }
  return MediaSaveInput(file.openRead(), length: await file.length());
}

Future<MediaSaveResult> saveMediaToPlatform({
  required String fileName,
  required bool isVideo,
  required Future<MediaSaveInput> Function() openSource,
  NetworkCancelToken? cancelToken,
  void Function(int received, int? total)? onProgress,
}) async {
  final useGallery = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  Directory? staging;
  RandomAccessFile? output;
  try {
    cancelToken?.throwIfCancelled();
    if (useGallery &&
        !await Gal.hasAccess(toAlbum: true) &&
        !await Gal.requestAccess(toAlbum: true)) {
      throw const MediaSaveException('相册访问被拒绝，请在系统设置中允许保存照片和视频。');
    }
    cancelToken?.throwIfCancelled();

    final Directory directory;
    if (useGallery) {
      directory = await getTemporaryDirectory();
    } else if (Platform.isWindows || Platform.isLinux) {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) {
        throw const MediaSaveException('无法找到下载目录，请检查系统的 Downloads 目录设置。');
      }
      directory = Directory('${downloads.path}/DanbooruViewer');
      await directory.create(recursive: true);
    } else {
      throw const MediaSaveException('当前平台暂不支持保存媒体文件。');
    }

    staging = await directory.createTemp('danbooru_save_');
    final temporary = File('${staging.path}/$fileName');
    output = await temporary.open(mode: FileMode.write);
    // Open the response only after permissions and the destination are ready.
    final input = await openSource();
    var received = 0;
    await for (final chunk in input.stream) {
      cancelToken?.throwIfCancelled();
      await output.writeFrom(chunk);
      received += chunk.length;
      onProgress?.call(received, input.length);
    }
    await output.flush();
    await output.close();
    output = null;
    cancelToken?.throwIfCancelled();
    if (received == 0) {
      throw const MediaSaveException('服务器返回了空文件，请重新加载后重试。');
    }
    if (input.length != null && received != input.length) {
      throw const MediaSaveException('媒体没有下载完整，请检查连接后重试。');
    }

    if (useGallery) {
      if (isVideo) {
        await Gal.putVideo(temporary.path, album: 'danbooru_viewer');
      } else {
        await Gal.putImage(temporary.path, album: 'danbooru_viewer');
      }
      return MediaSaveResult(
        destination: '相册 / danbooru_viewer',
        isVideo: isVideo,
      );
    }

    // A unique suffix prevents retries or concurrent saves overwriting a file.
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final extension = dot > 0 ? fileName.substring(dot) : '';
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch}_${_saveSequence++}';
    final destination = '${directory.path}/${stem}_$suffix$extension';
    await temporary.rename(destination);
    return MediaSaveResult(destination: destination, isVideo: isVideo);
  } on GalException catch (error) {
    throw MediaSaveException(switch (error.type) {
      GalExceptionType.accessDenied => '相册访问被拒绝，请在系统设置中允许保存照片和视频。',
      GalExceptionType.notEnoughSpace => '设备剩余空间不足，请释放空间后重试。',
      GalExceptionType.notSupportedFormat => '系统相册不支持此媒体格式，可打开原链接保存文件。',
      GalExceptionType.unexpected => '系统相册未能保存文件，请检查相册权限和剩余空间。',
    });
  } on FileSystemException {
    throw const MediaSaveException('无法写入媒体文件，请检查下载目录权限和设备剩余空间。');
  } finally {
    try {
      await output?.close();
    } on Object {
      // Keep the original download or write error.
    }
    if (staging != null) {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // A cleanup failure must not turn a completed save into a retry.
      }
    }
  }
}
