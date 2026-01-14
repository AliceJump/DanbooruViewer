import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';

class FullScreenImagePage extends StatefulWidget {
  final String previewUrl;
  final String? highResUrl;
  final String heroTag;

  const FullScreenImagePage({
    super.key,
    required this.previewUrl,
    this.highResUrl,
    required this.heroTag,
  });

  @override
  State<FullScreenImagePage> createState() => _FullScreenImagePageState();
}

class _FullScreenImagePageState extends State<FullScreenImagePage> {
  late String _currentImageUrl;
  ImageProvider? _imageProvider;
  bool _didLoadHighRes = false;

  @override
  void initState() {
    super.initState();
    _currentImageUrl = widget.previewUrl;
    _imageProvider = NetworkImage(_currentImageUrl);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoadHighRes) {
      _loadHighResImage();
      _didLoadHighRes = true;
    }
  }

  void _loadHighResImage() {
    if (widget.highResUrl != null && widget.highResUrl != widget.previewUrl) {
      precacheImage(NetworkImage(widget.highResUrl!), context).then((_) {
        if (mounted) {
          setState(() {
            _currentImageUrl = widget.highResUrl!;
            _imageProvider = NetworkImage(_currentImageUrl);
          });
        }
      });
    }
  }

  Future<void> _saveImage(BuildContext context) async {
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final status = await Gal.requestAccess();
        if (!status) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要存储权限来保存图片')),
          );
          return;
        }
      }
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/image.jpg';
      await Dio().download(_currentImageUrl, path);
      await Gal.putImage(path, album: 'danbooru_viewer');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图片已保存到相册')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        onLongPress: () => _saveImage(context),
        child: PhotoView(
          imageProvider: _imageProvider,
          heroAttributes: PhotoViewHeroAttributes(tag: widget.heroTag),
          loadingBuilder: (context, event) => Center(
            child: CircularProgressIndicator(
              value: event == null || event.expectedTotalBytes == null
                  ? null
                  : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
            ),
          ),
        ),
      ),
    );
  }
}
