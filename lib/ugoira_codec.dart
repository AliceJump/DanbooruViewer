import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ugoira_archive.dart';
import 'ugoira_bmp.dart';
import 'ugoira_jpeg.dart';
import 'ugoira_png.dart';
import 'ugoira_webp.dart';

const int _defaultFrameDelayMs = 60;
const int maxUgoiraZipBytes = 64 * 1024 * 1024;
const int _maxUncompressedBytes = 256 * 1024 * 1024;
const int _maxAnimationPixels = 64 * 1024 * 1024;
const int _maxJpegCoefficientBytes = 128 * 1024 * 1024;

// Shared by native compute and the browser worker. Keep this library free of
// Flutter and IO so the same limits and GIF output apply on every platform.
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
  var pngOutputBytes = 0;
  for (final file in imageFiles) {
    var data = file.content;
    final decoder = _frameDecoder(data);
    final remainingPixels = _maxAnimationPixels - totalPixels;
    final maxPixels = remainingPixels < 16 * 1024 * 1024
        ? remainingPixels
        : 16 * 1024 * 1024;
    final ({int width, int height}) dimensions;
    if (decoder is img.JpegDecoder) {
      final prepared = prepareUgoiraJpeg(
        data,
        maxPixels: maxPixels,
        maxCoefficientBytes: _maxJpegCoefficientBytes,
      );
      data = prepared.bytes;
      dimensions = (width: prepared.width, height: prepared.height);
    } else {
      if (decoder is img.PngDecoder) {
        final prepared = prepareUgoiraPng(
          data,
          maxPixels: maxPixels,
          maxOutputBytes: _maxUncompressedBytes - pngOutputBytes,
        );
        pngOutputBytes += prepared.outputBytes;
        data = prepared.bytes;
      } else if (decoder is img.BmpDecoder) {
        data = prepareUgoiraBmp(data, maxPixels: maxPixels).bytes;
      } else if (decoder is img.WebPDecoder) {
        data = prepareUgoiraWebp(data, maxPixels: maxPixels).bytes;
      }
      final info = decoder.startDecode(data);
      if (info == null) continue;
      dimensions = (width: info.width, height: info.height);
    }
    final pixels = dimensions.width * dimensions.height;
    totalPixels += pixels;
    if (dimensions.width <= 0 ||
        dimensions.height <= 0 ||
        dimensions.width > 0xffff ||
        dimensions.height > 0xffff ||
        pixels > 16 * 1024 * 1024 ||
        totalPixels > _maxAnimationPixels) {
      throw const FormatException('动图解码尺寸过大，请打开原链接查看。');
    }
    // JPEG's startDecode/readInfo also allocates coefficient blocks. The
    // preflight supplies dimensions so direct decode allocates them once.
    final frame = decoder is img.JpegDecoder
        ? decoder.decode(data)
        : decoder.decodeFrame(0);
    if (frame == null) continue;
    if (frame.width <= 0 ||
        frame.height <= 0 ||
        frame.width * frame.height != pixels) {
      throw const FormatException('动图帧解码尺寸与已验证的数据不一致。');
    }
    final delayMs = frameDelays[file.name] ?? _defaultFrameDelayMs;
    // GifEncoder 的 duration 单位为 1/100 秒。
    final centi = delayMs ~/ 10;
    // GIF palette quantization expects 8-bit channels. PNG may legitimately
    // carry 16-bit samples even when its scanline and pixel budgets are small.
    final gifFrame = frame.format == img.Format.uint16
        ? frame.convert(format: img.Format.uint8)
        : frame;
    // image 4.8.0 computes the sample count before its small-image fallback.
    // With its default factor 10, frames below 10 pixels train no colors.
    encoder.samplingFactor = pixels < 10 ? 1 : 10;
    encoder.addFrame(gifFrame, duration: centi < 1 ? 1 : centi);
  }

  final gif = encoder.finish();
  if (gif == null) {
    throw Exception('GIF 编码失败');
  }
  return gif;
}

img.Decoder _frameDecoder(Uint8List bytes) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  // Do not run general decoder probing on untrusted frames. Some format
  // detectors parse metadata; only these four explicit signatures are used.
  if (startsWith(const [137, 80, 78, 71, 13, 10, 26, 10])) {
    return img.PngDecoder();
  }
  if (startsWith(const [0xff, 0xd8])) return img.JpegDecoder();
  if (startsWith(const [82, 73, 70, 70]) &&
      startsWith(const [87, 69, 66, 80], 8)) {
    return img.WebPDecoder();
  }
  if (startsWith(const [66, 77])) return img.BmpDecoder();
  throw const FormatException('动图帧只支持 PNG、JPEG、WebP 和 BMP。');
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
