import 'package:flutter/material.dart';

import 'media_utils.dart';

class ReusableImageView extends StatelessWidget {
  final String imageUrl;
  final String tag;
  final BoxFit fit;

  const ReusableImageView({
    super.key,
    required this.imageUrl,
    required this.tag,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPress: () => saveMediaToGallery(context, imageUrl),
    child: Hero(
      tag: tag,
      child: CachedMediaImage(imageUrl: imageUrl, fit: fit),
    ),
  );
}
