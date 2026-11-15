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
import 'package:image/image.dart' as img;

import 'network/app_cache_manager.dart';
import 'network/app_network_service.dart';
import 'ugoira_archive.dart';

/// frame_data.json 缺失时使用的默认帧时长（毫秒）。
const int _defaultFrameDelayMs = 60;
const int maxUgoiraZipBytes = 64 * 1024 * 1024;
const int _maxUncompressedBytes = 256 * 1024 * 1024;
const int _maxAnimationPixels = 64 * 1024 * 1024;
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
  _UgoiraCacheGeneration(this.cache, this.network)
    : revision = network.revision;

  final CacheManager cache;
  final AppNetworkService network;
  final int revision;

  // Preserve existing files for the initial route. Later routes publish under
  // distinct keys, so a delayed old disk write cannot replace a new result.
  String keyFor(String key) =>
      revision == 0 ? key : '$key::network-revision=$revision';

  void checkCurrent() {
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
}) async {
  final generation = _UgoiraCacheGeneration(
    cacheManager ?? AppCacheManager.instance,
    networkService ?? AppNetworkService.instance,
  );
  final key = generation.keyFor(ugoiraGifCacheFileName(zipUrl));
  final requestKey = (generation.cache, generation.network, key);
  final existing = _pendingGifConversions[requestKey];
  if (existing != null) return generation.waitFor(existing);
  late Future<File> conversion;
  conversion =
      (() async {
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
          ),
        );
        if (await generation.waitFor(zip.length()) > maxUgoiraZipBytes) {
          throw const FormatException('动图压缩包过大，请打开原链接查看。');
        }
        final zipBytes = await generation.waitFor(zip.readAsBytes());
        final bytes = await generation.waitFor(
          compute(mergeUgoiraBytesToGifSync, zipBytes),
        );
        // The shared cache bounds and expires converted GIFs on native and Web.
        return generation.waitFor(
          generation.cache.putFile(
            zipUrl,
            bytes,
            key: key,
            fileExtension: 'gif',
            maxAge: const Duration(days: 30),
          ),
        );
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
  int maxBytes = maxUgoiraZipBytes,
}) async {
  final generation = _UgoiraCacheGeneration(
    cacheManager ?? AppCacheManager.instance,
    networkService ?? AppNetworkService.instance,
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

/// Byte input works with the native file cache and the browser memory cache.
Uint8List mergeUgoiraBytesToGifSync(Uint8List bytes) {
  if (bytes.length > maxUgoiraZipBytes) {
    throw const FormatException('动图压缩包过大，请打开原链接查看。');
  }
  final archive = decodeBoundedUgoiraArchive(
    bytes,
    maxOutputBytes: _maxUncompressedBytes,
  );
  final files = archive.files.where((f) => f.isFile).toList();

  final frameDelays = <String, int>{};
  final orderedNames = <String>[];

  for (final metaName in ['frame_data.json', 'motion.json']) {
    final metaFile = files
        .where((f) => f.name.toLowerCase() == metaName)
        .firstOrNull;
    if (metaFile == null) continue;
    try {
      final payload = json.decode(utf8.decode(metaFile.content));
      final frames = payload is Map<String, dynamic> ? payload['frames'] : null;
      if (frames is List) {
        if (frames.length > maxUgoiraArchiveFiles) continue;
        for (final frame in frames) {
          if (frame is! Map) continue;
          final name = frame['file']?.toString();
          if (name == null || name.isEmpty) continue;
          orderedNames.add(name);
          final delay = frame['delay'];
          frameDelays[name] = delay is num
              ? delay.toInt()
              : _defaultFrameDelayMs;
        }
        break;
      }
    } catch (_) {
      // 元数据解析失败时退化为按文件名排序。
    }
  }

  final imageFiles = files.where((f) {
    final n = f.name.toLowerCase();
    return n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.webp') ||
        n.endsWith('.bmp');
  }).toList();

  if (imageFiles.isEmpty) {
    throw Exception('ugoira zip 中未找到帧图片');
  }

  imageFiles.sort((a, b) {
    final ia = orderedNames.indexOf(a.name);
    final ib = orderedNames.indexOf(b.name);
    if (ia != -1 && ib != -1) return ia.compareTo(ib);
    if (ia != -1) return -1;
    if (ib != -1) return 1;
    return _naturalCompare(a.name, b.name);
  });

  final encoder = img.GifEncoder(repeat: 0);
  var totalPixels = 0;
  for (final file in imageFiles) {
    final data = file.content;
    final decoder = img.findDecoderForData(data);
    final info = decoder?.startDecode(data);
    if (info == null) continue;
    final pixels = info.width * info.height;
    totalPixels += pixels;
    if (pixels > 16 * 1024 * 1024 || totalPixels > _maxAnimationPixels) {
      throw const FormatException('动图解码尺寸过大，请打开原链接查看。');
    }
    final frame = decoder!.decodeFrame(0);
    if (frame == null) continue;
    final delayMs = frameDelays[file.name] ?? _defaultFrameDelayMs;
    // GifEncoder 的 duration 单位为 1/100 秒。
    final centi = delayMs ~/ 10;
    encoder.addFrame(frame, duration: centi < 1 ? 1 : centi);
  }

  final gif = encoder.finish();
  if (gif == null) {
    throw Exception('GIF 编码失败');
  }
  return gif;
}

/// 自然排序：数字段按数值比较，其余按字典序。
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final partsA = re.allMatches(a).map((m) => m.group(0)!).toList();
  final partsB = re.allMatches(b).map((m) => m.group(0)!).toList();
  final len = partsA.length < partsB.length ? partsA.length : partsB.length;
  for (var i = 0; i < len; i++) {
    final sa = partsA[i];
    final sb = partsB[i];
    if (sa == sb) continue;
    final na = int.tryParse(sa);
    final nb = int.tryParse(sb);
    if (na != null && nb != null) return na.compareTo(nb);
    return sa.compareTo(sb);
  }
  return partsA.length.compareTo(partsB.length);
}
