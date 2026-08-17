// ugoira_utils.dart
//
// Danbooru 的 ugoira 动画帖（Pixiv 无声音动图）的源文件是一个 .zip 压缩包，
// 内含逐帧图片和一个 frame_data.json（记录每帧文件名与时长，单位毫秒）。
// 这里负责：下载 zip -> 解出帧图 -> 按 frame_data 顺序与时长合并成 GIF，
// 后续代码把 GIF 当作普通图片文件继续走原有图片显示/保存逻辑。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// frame_data.json 缺失时使用的默认帧时长（毫秒）。
const int _defaultFrameDelayMs = 60;

/// 判断 URL 是否是 ugoira 动画压缩包（.zip）。
bool isUgoiraUrl(String? url) {
  if (url == null) return false;
  final lower = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return lower.endsWith('.zip');
}

Future<Directory> _cacheDir() async {
  final temp = await getTemporaryDirectory();
  final dir = Directory(
    '${temp.path}${Platform.pathSeparator}ugoira_gif_cache',
  );
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

String _cacheFileName(String url) {
  final hash = url.hashCode.toRadixString(16);
  return 'ugoira_$hash.gif';
}

Future<File> _cachedGifFile(String url) async {
  final dir = await _cacheDir();
  return File('${dir.path}${Platform.pathSeparator}${_cacheFileName(url)}');
}

/// 仅返回已缓存的 ugoira GIF 文件；未处理过时返回 null（不会触发处理）。
Future<File?> getCachedUgoiraGifFile(String zipUrl) async {
  final cached = await _cachedGifFile(zipUrl);
  if (await cached.exists() && await cached.length() > 0) return cached;
  return null;
}

/// 下载 ugoira zip 并合并为 GIF，结果缓存到临时目录。
/// 已缓存时直接返回，避免重复处理。
Future<File> getUgoiraGifFile(String zipUrl, {int retries = 2}) async {
  final cached = await _cachedGifFile(zipUrl);
  if (await cached.exists() && await cached.length() > 0) {
    return cached;
  }

  var attempt = 0;
  late File zipFile;
  while (true) {
    try {
      zipFile = await DefaultCacheManager().getSingleFile(zipUrl);
      break;
    } catch (_) {
      if (attempt++ >= retries) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
    }
  }

  final gifBytes = await compute(mergeUgoiraToGifSync, zipFile.path);
  await cached.writeAsBytes(gifBytes, flush: true);
  return cached;
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
  final bytes = File(zipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  final files = archive.files.where((f) => f.isFile).toList();

  final frameDelays = <String, int>{};
  final orderedNames = <String>[];

  for (final metaName in ['frame_data.json', 'motion.json']) {
    final metaFile = files
        .where(
          (f) => f.name.toLowerCase() == metaName,
        )
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

  final imageFiles = files
      .where((f) {
        final n = f.name.toLowerCase();
        return n.endsWith('.png') ||
            n.endsWith('.jpg') ||
            n.endsWith('.jpeg') ||
            n.endsWith('.webp') ||
            n.endsWith('.bmp');
      })
      .toList();

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
  for (final file in imageFiles) {
    final frame = img.decodeImage(file.content);
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
  final len = partsA.length < partsB.length
      ? partsA.length
      : partsB.length;
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