// ugoira_utils.dart
//
// Danbooru 的 ugoira 动画帖（Pixiv 无声音动图）的源文件是一个 .zip 压缩包，
// 内含逐帧图片和一个 frame_data.json（记录每帧文件名与时长，单位毫秒）。
// 这里负责：下载 zip -> 解出帧图 -> 按 frame_data 顺序与时长合并成 GIF，
// 后续代码把 GIF 当作普通图片文件继续走原有图片显示/保存逻辑。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'network/app_cache_manager.dart';
import 'network/app_network_service.dart';
import 'ugoira_codec.dart';
import 'ugoira_conversion.dart';

export 'ugoira_codec.dart' show maxUgoiraZipBytes, mergeUgoiraBytesToGifSync;

final Map<Object, Future<File>> _pendingGifConversions = {};

/// 判断 URL 是否是 ugoira 动画压缩包（.zip）。
bool isUgoiraUrl(String? url) {
  if (url == null) return false;
  final lower = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return lower.endsWith('.zip');
}

@visibleForTesting
String ugoiraGifCacheFileName(String url) {
  final hash = sha256.convert(utf8.encode(url));
  return 'ugoira_$hash.gif';
}

class _UgoiraCacheGeneration {
  _UgoiraCacheGeneration(this.cache, this.network, [this.cancelToken])
    : revision = network.revision;

  final CacheManager cache;
  final AppNetworkService network;
  final NetworkCancelToken? cancelToken;
  final int revision;

  // Preserve existing files for the initial route. Later routes publish under
  // distinct keys, so a delayed old disk write cannot replace a new result.
  String keyFor(String key) =>
      revision == 0 ? key : '$key::network-revision=$revision';

  void checkCurrent() {
    cancelToken?.throwIfCancelled();
    if (network.revision != revision) {
      throw const NetworkCancelledException('网络设置已更改，请重新加载。');
    }
  }

  Future<T> waitFor<T>(Future<T> operation) async {
    final T result;
    try {
      result = await operation;
    } catch (_) {
      checkCurrent();
      rethrow;
    }
    checkCurrent();
    return result;
  }
}

/// 仅返回已缓存的 ugoira GIF 文件；未处理过时返回 null（不会触发处理）。
Future<File?> getCachedUgoiraGifFile(
  String zipUrl, {
  CacheManager? cacheManager,
  AppNetworkService? networkService,
}) async {
  final generation = _UgoiraCacheGeneration(
    cacheManager ?? AppCacheManager.instance,
    networkService ?? AppNetworkService.instance,
  );
  final cached = await generation.waitFor(
    generation.cache.getFileFromCache(
      generation.keyFor(ugoiraGifCacheFileName(zipUrl)),
    ),
  );
  if (cached != null &&
      cached.validTill.isAfter(DateTime.now()) &&
      await generation.waitFor(cached.file.exists()) &&
      await generation.waitFor(cached.file.length()) > 0) {
    return cached.file;
  }
  return null;
}

/// 下载 ugoira zip 并合并为 GIF，结果缓存到临时目录。
/// 已缓存时直接返回，避免重复处理。
Future<File> getUgoiraGifFile(
  String zipUrl, {
  int retries = 2,
  CacheManager? cacheManager,
  AppNetworkService? networkService,
  NetworkCancelToken? cancelToken,
}) async {
  cancelToken?.throwIfCancelled();
  final generation = _UgoiraCacheGeneration(
    cacheManager ?? AppCacheManager.instance,
    networkService ?? AppNetworkService.instance,
    cancelToken,
  );
  final key = generation.keyFor(ugoiraGifCacheFileName(zipUrl));
  // Uncancelled viewers still share work. An explicitly cancellable caller
  // owns its task, so stopping it cannot abort a different viewer's request.
  final requestKey = (generation.cache, generation.network, key, cancelToken);
  final existing = _pendingGifConversions[requestKey];
  if (existing != null) return generation.waitFor(existing);
  late Future<File> conversion;
  conversion =
      (() async {
        final conversionToken = NetworkCancelToken();
        final removeCancelListener = cancelToken?.addListener(
          conversionToken.cancel,
        );
        void cancelOldRoute() {
          if (generation.network.revision != generation.revision) {
            conversionToken.cancel();
          }
        }

        generation.network.addListener(cancelOldRoute);
        try {
          generation.checkCurrent();
          final cached = await generation.waitFor(
            getCachedUgoiraGifFile(
              zipUrl,
              cacheManager: generation.cache,
              networkService: generation.network,
            ),
          );
          if (cached != null) return cached;
          final zip = await generation.waitFor(
            getBoundedUgoiraZipFile(
              zipUrl,
              cacheManager: generation.cache,
              networkService: generation.network,
              cancelToken: conversionToken,
            ),
          );
          if (await generation.waitFor(zip.length()) > maxUgoiraZipBytes) {
            throw const FormatException('动图压缩包过大，请打开原链接查看。');
          }
          final zipBytes = await generation.waitFor(zip.readAsBytes());
          final bytes = await generation.waitFor(
            convertUgoiraBytesToGif(zipBytes, cancelToken: conversionToken),
          );
          // The shared cache bounds and expires GIFs on native and Web.
          return await generation.waitFor(
            generation.cache.putFile(
              zipUrl,
              bytes,
              key: key,
              fileExtension: 'gif',
              maxAge: const Duration(days: 30),
            ),
          );
        } finally {
          generation.network.removeListener(cancelOldRoute);
          removeCancelListener?.call();
          conversionToken.cancel();
        }
      })().whenComplete(() {
        if (identical(_pendingGifConversions[requestKey], conversion)) {
          _pendingGifConversions.remove(requestKey);
        }
      });
  _pendingGifConversions[requestKey] = conversion;
  return generation.waitFor(conversion);
}

/// Never publish an oversized response to the cache, including when its
/// Content-Length is absent or dishonest. The stream is cancelled on failure.
Future<File> getBoundedUgoiraZipFile(
  String zipUrl, {
  CacheManager? cacheManager,
  AppNetworkService? networkService,
  NetworkCancelToken? cancelToken,
  int maxBytes = maxUgoiraZipBytes,
}) async {
  cancelToken?.throwIfCancelled();
  final generation = _UgoiraCacheGeneration(
    cacheManager ?? AppCacheManager.instance,
    networkService ?? AppNetworkService.instance,
    cancelToken,
  );
  final cache = generation.cache;
  final key = generation.keyFor(zipUrl);
  final cached = await generation.waitFor(cache.getFileFromCache(key));
  if (cached != null && await generation.waitFor(cached.file.exists())) {
    final size = await generation.waitFor(cached.file.length());
    if (size > maxBytes) {
      await generation.waitFor(cache.removeFile(key));
      throw const FormatException('动图压缩包过大，请打开原链接查看。');
    }
    if (size > 0 && cached.validTill.isAfter(DateTime.now())) {
      return cached.file;
    }
  }
  final token = NetworkCancelToken();
  final removeCancelListener = cancelToken?.addListener(token.cancel);
  try {
    final response = await generation.waitFor(
      generation.network.stream(Uri.parse(zipUrl), cancelToken: token),
    );
    if (response.statusCode != 200) {
      await generation.waitFor(response.stream.listen(null).cancel());
      throw NetworkException(
        NetworkErrorKind.http,
        httpStatusMessage(response.statusCode),
        statusCode: response.statusCode,
      );
    }
    final cacheHeaders = HttpGetResponse(response);
    final validTill = cacheHeaders.validTill;
    final bytes = await generation.waitFor(
      readBoundedUgoiraZipBytes(
        response.stream,
        cancelToken: token,
        maxBytes: maxBytes,
      ),
    );
    token.throwIfCancelled();
    if (bytes.isEmpty) throw const FormatException('动图压缩包为空。');
    return await generation.waitFor(
      cache.putFile(
        zipUrl,
        bytes,
        key: key,
        fileExtension: 'zip',
        maxAge: validTill.difference(DateTime.now()),
        eTag: cacheHeaders.eTag,
      ),
    );
  } finally {
    removeCancelListener?.call();
    token.cancel();
  }
}

Future<Uint8List> readBoundedUgoiraZipBytes(
  Stream<List<int>> source, {
  NetworkCancelToken? cancelToken,
  int maxBytes = maxUgoiraZipBytes,
  int? total,
  void Function(int received, int? total)? onProgress,
}) async {
  cancelToken?.throwIfCancelled();
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in source) {
    cancelToken?.throwIfCancelled();
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('动图压缩包过大，请打开原链接查看。');
    }
    bytes.add(chunk);
    onProgress?.call(bytes.length, total);
  }
  cancelToken?.throwIfCancelled();
  return bytes.takeBytes();
}

@visibleForTesting
Future<File> cacheUgoiraGifFile(
  File cached,
  Future<Uint8List> Function() convert,
) {
  final cachePath = cached.path;
  final pending = _pendingGifConversions[cachePath];
  if (pending != null) return pending;

  late Future<File> conversion;
  conversion = _convertAndCacheGif(cached, convert).whenComplete(() {
    if (identical(_pendingGifConversions[cachePath], conversion)) {
      _pendingGifConversions.remove(cachePath);
    }
  });
  _pendingGifConversions[cachePath] = conversion;
  return conversion;
}

Future<File> _convertAndCacheGif(
  File cached,
  Future<Uint8List> Function() convert,
) async {
  if (await cached.exists()) {
    if (await cached.length() > 0) return cached;
    await cached.delete();
  }

  final gifBytes = await convert();
  final temporary = File(
    '${cached.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temporary.writeAsBytes(gifBytes, flush: true);
    await temporary.rename(cached.path);
    return cached;
  } finally {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on FileSystemException {
      // Preserve the original conversion or rename failure.
    }
  }
}

/// 触发 ugoira GIF 处理（不等待结果），用于预热。
Future<void> ensureUgoiraGifCached(String zipUrl) async {
  try {
    await getUgoiraGifFile(zipUrl);
  } catch (e) {
    debugPrint('Failed to process ugoira $zipUrl: $e');
  }
}

/// 后台 isolate 顶层函数：读取 zip 文件，按帧顺序/时长合并成 GIF 字节。
Uint8List mergeUgoiraToGifSync(String zipPath) {
  return mergeUgoiraBytesToGifSync(File(zipPath).readAsBytesSync());
}
