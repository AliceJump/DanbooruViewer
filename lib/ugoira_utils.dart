// ugoira_utils.dart
//
// Danbooru 的 ugoira 动画帖（Pixiv 无声音动图）的源文件是一个 .zip 压缩包，
// 内含逐帧图片和一个 frame_data.json（记录每帧文件名与时长，单位毫秒）。
// 这里负责：下载 zip -> 解出帧图 -> 按 frame_data 顺序与时长合并成 GIF，
// 后续代码把 GIF 当作普通图片文件继续走原有图片显示/保存逻辑。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'network/app_cache_manager.dart';

/// frame_data.json 缺失时使用的默认帧时长（毫秒）。
const int _defaultFrameDelayMs = 60;
const int maxUgoiraZipBytes = 64 * 1024 * 1024;
const int _maxUncompressedBytes = 256 * 1024 * 1024;
const int _maxAnimationPixels = 64 * 1024 * 1024;
final Map<String, Future<File>> _pendingGifConversions = {};

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

/// 仅返回已缓存的 ugoira GIF 文件；未处理过时返回 null（不会触发处理）。
Future<File?> getCachedUgoiraGifFile(String zipUrl) async {
  final cached = await AppCacheManager.instance.getFileFromCache(
    ugoiraGifCacheFileName(zipUrl),
  );
  if (cached != null && await cached.file.length() > 0) return cached.file;
  return null;
}

/// 下载 ugoira zip 并合并为 GIF，结果缓存到临时目录。
/// 已缓存时直接返回，避免重复处理。
Future<File> getUgoiraGifFile(String zipUrl, {int retries = 2}) async {
  final key = ugoiraGifCacheFileName(zipUrl);
  final existing = _pendingGifConversions[key];
  if (existing != null) return existing;
  late Future<File> conversion;
  conversion =
      (() async {
        final cached = await getCachedUgoiraGifFile(zipUrl);
        if (cached != null) return cached;
        final zip = await AppCacheManager.instance.getSingleFile(zipUrl);
        if (await zip.length() > maxUgoiraZipBytes) {
          throw const FormatException('动图压缩包过大，请打开原链接查看。');
        }
        final bytes = await compute(
          mergeUgoiraBytesToGifSync,
          await zip.readAsBytes(),
        );
        // The shared cache bounds and expires converted GIFs on native and Web.
        return AppCacheManager.instance.putFile(
          zipUrl,
          bytes,
          key: key,
          fileExtension: 'gif',
          maxAge: const Duration(days: 30),
        );
      })().whenComplete(() {
        if (identical(_pendingGifConversions[key], conversion)) {
          _pendingGifConversions.remove(key);
        }
      });
  _pendingGifConversions[key] = conversion;
  return conversion;
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
  final archive = ZipDecoder().decodeBytes(bytes);
  final files = archive.files.where((f) => f.isFile).toList();
  if (files.length > 502 ||
      files.fold<int>(0, (total, file) => total + file.size) >
          _maxUncompressedBytes) {
    throw const FormatException('动图帧数或解压大小超出限制，请打开原链接查看。');
  }

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
