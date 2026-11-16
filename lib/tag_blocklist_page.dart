import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tag_blocklist.dart';

Future<void> _undoBlocklistChange(
  ScaffoldMessengerState messenger,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (messenger.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('撤销未能保存，请在标签屏蔽中重试。')),
      );
    }
  }
}

class TagBlocklistPage extends StatefulWidget {
  const TagBlocklistPage({super.key, this.blocklist});

  final TagBlocklist? blocklist;

  @override
  State<TagBlocklistPage> createState() => _TagBlocklistPageState();
}

class _TagBlocklistPageState extends State<TagBlocklistPage> {
  final _input = TextEditingController();
  final _search = TextEditingController();
  bool _saving = false;
  String? _error;
  TagBlocklist get _store => widget.blocklist ?? TagBlocklistScope.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_store.initialize());
  }

  @override
  void dispose() {
    _input.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _change(
    Future<void> Function() action, {
    String failureMessage = '设置未能保存，原有屏蔽规则保持不变，请重试。',
  }) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is FormatException ? error.message : failureMessage;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyRaw() => _change(() async {
    final raw = await _store.rawBackup();
    await Clipboard.setData(ClipboardData(text: raw));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制原始屏蔽数据')));
  }, failureMessage: '原始屏蔽数据未能复制，请重试。');

  Future<void> _add() => _change(() async {
    final tags = _input.text
        .split(RegExp(r'\s+'))
        .where((tag) => tag.isNotEmpty);
    if (tags.isEmpty) throw const FormatException('请先输入要屏蔽的标签');
    final store = _store;
    final added = await store.addTags(tags);
    if (!mounted) return;
    _input.clear();
    FocusScope.of(context).unfocus();
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          added.isEmpty ? '这些标签已在屏蔽列表中' : '已添加 ${added.length} 个屏蔽标签',
        ),
        action: added.isEmpty
            ? null
            : SnackBarAction(
                label: '撤销',
                onPressed: () => unawaited(
                  _undoBlocklistChange(
                    messenger,
                    () => store.removeTags(added),
                  ),
                ),
              ),
      ),
    );
  });

  Future<void> _remove(String tag) => _change(() async {
    final store = _store;
    await store.removeTags([tag]);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('已解除屏蔽：$tag'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => unawaited(
            _undoBlocklistChange(messenger, () async {
              await store.addTags([tag], endTemporaryReveal: false);
            }),
          ),
        ),
      ),
    );
  });

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Scaffold(
      appBar: AppBar(title: const Text('标签屏蔽')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: AnimatedBuilder(
              animation: store,
              builder: (context, _) {
                final query = TagBlocklist.canonicalTag(_search.text);
                final tags = store.tags
                    .where((tag) => tag.contains(query))
                    .toList();
                return CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('启用标签屏蔽'),
                              subtitle: const Text('隐藏命中任意完整标签的作品；保留收藏和历史记录'),
                              value: store.enabled,
                              onChanged: _saving || store.loadError != null
                                  ? null
                                  : (value) =>
                                        _change(() => store.setEnabled(value)),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '使用原始标签名，多个标签用空格或换行分隔。例如 cat 只匹配 cat，不匹配 cat_ears。这里不解析通配符或搜索表达式。',
                            ),
                            if (store.temporarilyShow) ...[
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: () =>
                                    store.setTemporarilyShow(false),
                                child: const Text('结束临时显示，恢复屏蔽'),
                              ),
                            ],
                            if (store.loadError != null) ...[
                              const SizedBox(height: 16),
                              Text(
                                store.loadError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                              if (_error != null)
                                Text(
                                  _error!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: store.retryLoad,
                                    child: const Text('重试读取'),
                                  ),
                                  TextButton(
                                    onPressed: _saving ? null : _copyRaw,
                                    child: const Text('复制原始数据'),
                                  ),
                                ],
                              ),
                            ] else ...[
                              const SizedBox(height: 16),
                              TextField(
                                controller: _input,
                                minLines: 1,
                                maxLines: 4,
                                enabled: !_saving,
                                decoration: InputDecoration(
                                  labelText: '添加屏蔽标签',
                                  hintText: '例如：cat blue_hair',
                                  errorText: _error,
                                  border: const OutlineInputBorder(),
                                ),
                                onSubmitted: (_) => _add(),
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FilledButton.icon(
                                  onPressed: _saving ? null : _add,
                                  icon: const Icon(Icons.block),
                                  label: Text(_saving ? '正在保存…' : '添加标签'),
                                ),
                              ),
                            ],
                            const Divider(height: 32),
                            Text(
                              '已保存 ${store.tags.length} 个标签',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (store.tags.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _search,
                                decoration: const InputDecoration(
                                  labelText: '查找屏蔽标签',
                                  prefixIcon: Icon(Icons.search),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                            if (tags.isEmpty) ...[
                              const SizedBox(height: 24),
                              Text(
                                store.tags.isEmpty
                                    ? '还没有屏蔽标签。也可以在作品详情的标签菜单中添加。'
                                    : '没有匹配的屏蔽标签',
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: tags.length,
                      itemBuilder: (context, index) {
                        final tag = tags[index];
                        return ListTile(
                          title: Text(tag),
                          trailing: IconButton(
                            tooltip: '解除屏蔽 $tag',
                            onPressed: _saving ? null : () => _remove(tag),
                            icon: const Icon(Icons.close),
                          ),
                        );
                      },
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class TagBlocklistStatus extends StatelessWidget {
  const TagBlocklistStatus({
    super.key,
    required this.hiddenCount,
    this.blocklist,
  });

  final int hiddenCount;
  final TagBlocklist? blocklist;

  @override
  Widget build(BuildContext context) {
    final store = blocklist ?? TagBlocklistScope.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        if (store.loadError == null && store.tags.isEmpty) {
          return const SizedBox();
        }
        final status = store.loadError != null
            ? '屏蔽列表读取失败'
            : !store.enabled
            ? '标签屏蔽已关闭'
            : store.temporarilyShow
            ? '正在临时显示被屏蔽的作品'
            : '已屏蔽 $hiddenCount 项';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(status),
              if (store.enabled && store.loadError == null)
                TextButton(
                  onPressed: () =>
                      store.setTemporarilyShow(!store.temporarilyShow),
                  child: Text(store.temporarilyShow ? '恢复屏蔽' : '临时显示'),
                ),
              TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TagBlocklistPage(blocklist: store),
                  ),
                ),
                child: const Text('管理屏蔽'),
              ),
            ],
          ),
        );
      },
    );
  }
}
