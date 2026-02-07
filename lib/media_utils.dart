// media_utils.dart
import 'package:gal/gal.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// drag_utils.dart
import 'package:danbooru_viewer/DragHelper.dart';

/// 判断 URL 是否是视频
bool isVideoUrl(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.mp4') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.m4v');
}

/// 获取缓存文件（支持重试）
Future<File> getCachedFile(String url, {int retries = 2}) async {
  var attempt = 0;
  while (true) {
    try {
      return await DefaultCacheManager().getSingleFile(url);
    } catch (_) {
      if (attempt++ >= retries) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
    }
  }
}

/// 触发原生拖拽
/// [context] 用于 SnackBar 提示错误
/// [mediaUrl] 图片或视频 URL
Future<void> startDrag(BuildContext context, String media) async {
  if (media.isEmpty) return;

  final type = isVideoUrl(media) ? "video" : "image";
  String filePath;

  try {
    if (media.startsWith('http://') || media.startsWith('https://')) {
      // URL → 获取缓存文件
      filePath = (await getCachedFile(media)).path;
    } else {
      // 本地文件路径
      filePath = media;
    }

    await DragHelper.startDrag(filePath, type: type);
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('无法拖拽: $e')),
    );
  }
}


Future<void> saveMediaToGallery(BuildContext context, String mediaUrl) async {
  try {
    final hasAccess = await Gal.hasAccess();
    if (!hasAccess) {
      final status = await Gal.requestAccess();
      if (!status) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要存储权限来保存文件')));
        return;
      }
    }

    // 判断是网络 URL 还是本地路径
    final file = (mediaUrl.startsWith('http://') || mediaUrl.startsWith('https://'))
        ? await DefaultCacheManager().getSingleFile(mediaUrl)
        : File(mediaUrl);

    final isVideo = mediaUrl.toLowerCase().endsWith('.mp4');

    if (isVideo) {
      await Gal.putVideo(file.path, album: 'danbooru_viewer');
    } else {
      await Gal.putImage(file.path, album: 'danbooru_viewer');
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${isVideo ? '视频' : '图片'}已保存到相册')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('保存失败: $e')));
  }
}
