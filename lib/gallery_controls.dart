import 'package:flutter/material.dart';

/// Search stays independent from the completion engine and gallery requests.
class GallerySearchPanel extends StatelessWidget {
  const GallerySearchPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.selectedTags,
    required this.filters,
    required this.onSearch,
    required this.onSubmitted,
    required this.onClear,
    required this.hasQuery,
    this.suggestions,
    this.expanded = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<Widget> selectedTags;
  final List<Widget> filters;
  final VoidCallback onSearch;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;
  final bool hasQuery;
  final Widget? suggestions;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (expanded) ...[
              Text('探索作品', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                '从一个标签开始，找到喜欢的作品。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
            ],
            TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '搜索...',
                hintText: '标签、角色或作品名',
                suffixIcon: IconButton(
                  tooltip: '搜索作品',
                  icon: const Icon(Icons.search),
                  onPressed: onSearch,
                ),
              ),
              onTapOutside: (_) => focusNode.unfocus(),
              onSubmitted: onSubmitted,
            ),
            if (suggestions != null) ...[
              const SizedBox(height: 8),
              suggestions!,
            ],
            if (selectedTags.isNotEmpty) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 112),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: selectedTags,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (expanded) ...[
              Text('内容分级', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 4, children: filters),
            ] else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final filter in filters)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: filter,
                      ),
                  ],
                ),
              ),
            if (hasQuery)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onClear,
                  icon: const Icon(Icons.clear_all),
                  label: const Text('清空搜索'),
                ),
              ),
            if (expanded) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              Text(
                'Ctrl / ⌘ + F 聚焦搜索\nEsc 关闭建议或退出多选',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class GallerySectionHeader extends StatelessWidget {
  const GallerySectionHeader({
    super.key,
    required this.count,
    required this.isLoading,
    required this.onRefresh,
    required this.onSelect,
    this.compact = false,
  });

  final int count;
  final bool isLoading;
  final VoidCallback onRefresh;
  final VoidCallback? onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) Text('浏览作品', style: theme.textTheme.titleMedium),
                Text(
                  '$count 张作品',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: compact
                      ? theme.textTheme.bodyMedium
                      : theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '选择作品',
            onPressed: onSelect,
            icon: const Icon(Icons.checklist_outlined),
          ),
          IconButton(
            tooltip: '刷新作品',
            onPressed: isLoading ? null : onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}

class GalleryRequestFeedback extends StatelessWidget {
  const GalleryRequestFeedback({
    super.key,
    required this.message,
    required this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: message,
              child: Text(
                compact ? '加载失败' : message,
                semanticsLabel: message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('重试加载')),
          ],
        ),
      ),
    );
  }
}
