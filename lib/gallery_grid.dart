import 'package:flutter/material.dart';

const double _gallerySpacing = 8;
const double _galleryPadding = 12;
const double _targetTileExtent = 152;

int galleryColumnCount(double width) {
  final contentWidth = width - _galleryPadding * 2;
  final count =
      ((contentWidth + _gallerySpacing) / (_targetTileExtent + _gallerySpacing))
          .floor();
  return count.clamp(2, 8).toInt();
}

class GalleryGrid extends StatelessWidget {
  const GalleryGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.onRefresh,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final grid = GridView.builder(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(_galleryPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: galleryColumnCount(constraints.maxWidth),
            mainAxisSpacing: _gallerySpacing,
            crossAxisSpacing: _gallerySpacing,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
        return onRefresh == null
            ? grid
            : RefreshIndicator(onRefresh: onRefresh!, child: grid);
      },
    );
  }
}

class GalleryEmptyState extends StatelessWidget {
  const GalleryEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 40,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (action != null) ...[
                      const SizedBox(height: 20),
                      action!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
