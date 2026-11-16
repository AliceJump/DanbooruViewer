import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'favorites_manager.dart';
import 'network/network_settings_page.dart';
import 'tag_blocklist.dart';
import 'tag_blocklist_page.dart';

Future<void> copyCollectionBackup(
  BuildContext context, {
  FavoritesManager? manager,
}) async {
  try {
    final backup = await (manager ?? FavoritesManager()).exportBackupJson();
    await Clipboard.setData(ClipboardData(text: backup));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制收藏、历史和屏蔽设置的原始备份，可粘贴到文本文件保存。')),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('备份未能复制，请重试。原始数据未更改。')));
  }
}

class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({super.key, this.blocklist});

  final TagBlocklist? blocklist;

  @override
  Widget build(BuildContext context) {
    final store = blocklist ?? TagBlocklistScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.wifi),
                  title: const Text('网络与代理'),
                  subtitle: const Text('连接方式、代理地址和 API / CDN 检查'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NetworkSettingsPage(),
                    ),
                  ),
                ),
                AnimatedBuilder(
                  animation: store,
                  builder: (context, _) => ListTile(
                    leading: const Icon(Icons.block),
                    title: const Text('标签屏蔽'),
                    subtitle: Text(
                      store.loadError != null
                          ? '读取失败，原始数据已保留'
                          : '${store.tags.length} 个标签 · ${store.enabled ? '已启用' : '已关闭'}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TagBlocklistPage(blocklist: store),
                      ),
                    ),
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.copy_all_outlined),
                  title: const Text('复制收藏备份'),
                  subtitle: const Text('包含收藏、历史和屏蔽设置；损坏记录也会保留原文'),
                  onTap: () => copyCollectionBackup(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
