import 'dart:async';

import 'package:flutter/material.dart';

import 'media_save_service.dart';
import 'network/app_network_service.dart';
import 'post.dart';

typedef MediaSaver =
    Future<MediaSaveResult> Function(
      String source, {
      int? postId,
      NetworkCancelToken? cancelToken,
      void Function(int received, int? total)? onProgress,
    });

enum _DownloadState { pending, downloading, saved, failed, cancelled, skipped }

class _DownloadItem {
  _DownloadItem(this.post);

  final Post post;
  _DownloadState state = _DownloadState.pending;
  String? message;
}

/// A foreground queue: leaving the dialog cancels unfinished work explicitly.
/// Saved items are never included in retries or returned to the selection.
class DownloadProgressDialog extends StatefulWidget {
  const DownloadProgressDialog({
    super.key,
    required this.posts,
    this.saveMedia,
    this.canSave,
  });

  final List<Post> posts;
  final MediaSaver? saveMedia;

  /// Rechecked before every pending/retried item, including after an earlier
  /// download awaited a network request. Already-started writes are not undone.
  final bool Function(Post post)? canSave;

  @override
  State<DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<DownloadProgressDialog> {
  late final List<_DownloadItem> _items;
  NetworkCancelToken? _cancelToken;
  bool _running = false;
  bool _cancelRequested = false;
  double? _progress;

  int get _saved =>
      _items.where((item) => item.state == _DownloadState.saved).length;
  Set<int> get _unfinished => _items
      .where(
        (item) => item.state != _DownloadState.saved && _canSave(item.post),
      )
      .map((item) => item.post.id)
      .toSet();

  bool _canSave(Post post) => widget.canSave?.call(post) ?? true;

  @override
  void initState() {
    super.initState();
    final unique = <int, Post>{};
    for (final post in widget.posts) {
      unique.putIfAbsent(post.id, () => post);
    }
    _items = unique.values.map(_DownloadItem.new).toList();
    unawaited(_run());
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final cancelToken = NetworkCancelToken();
    _cancelToken = cancelToken;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = null;
      for (final item in _items) {
        if (item.state != _DownloadState.saved) {
          item.state = _DownloadState.pending;
          item.message = null;
        }
      }
    });
    for (final item in _items) {
      if (!mounted || _cancelRequested) break;
      if (item.state == _DownloadState.saved) continue;
      if (!_canSave(item.post)) {
        setState(() {
          item.state = _DownloadState.skipped;
          item.message = '作品已隐藏，未开始保存。';
        });
        continue;
      }
      setState(() {
        item.state = _DownloadState.downloading;
        _progress = null;
      });
      try {
        final source = item.post.fileUrl ?? item.post.largeFileUrl;
        if (source == null) {
          throw const FormatException('作品没有可下载的媒体地址');
        }
        final result = await (widget.saveMedia ?? saveMediaResource)(
          source,
          postId: item.post.id,
          cancelToken: cancelToken,
          onProgress: (received, total) {
            if (!mounted || _cancelRequested) return;
            setState(() {
              _progress = total != null && total > 0
                  ? (received / total).clamp(0.0, 1.0)
                  : null;
            });
          },
        );
        if (!mounted) return;
        setState(() {
          item.state = _DownloadState.saved;
          item.message = result.destination;
        });
      } catch (error) {
        if (!mounted) return;
        setState(() {
          item.state = _cancelRequested || error is NetworkCancelledException
              ? _DownloadState.cancelled
              : _DownloadState.failed;
          item.message = error is FormatException
              ? error.message
              : formatMediaSaveError(error);
        });
      }
    }
    if (!mounted) return;
    setState(() {
      for (final item in _items) {
        if (item.state == _DownloadState.pending) {
          item.state = _DownloadState.cancelled;
        }
      }
      _running = false;
      _progress = null;
    });
  }

  void _cancel() {
    if (!_running || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    _cancelToken?.cancel();
  }

  void _close() => Navigator.pop(context, _unfinished);

  String _label(_DownloadState state) => switch (state) {
    _DownloadState.pending => '等待下载',
    _DownloadState.downloading => '正在保存',
    _DownloadState.saved => '已保存',
    _DownloadState.failed => '保存失败',
    _DownloadState.cancelled => '已取消',
    _DownloadState.skipped => '已跳过',
  };

  @override
  Widget build(BuildContext context) {
    return PopScope<Set<int>>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (_running) {
            _cancel();
          } else {
            _close();
          }
        }
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(_running ? '保存作品' : '保存结果'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text('已保存 $_saved / ${_items.length} 项'),
              ),
              if (_running) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text(_cancelRequested ? '正在取消当前下载…' : '请保持此窗口打开'),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: (MediaQuery.sizeOf(context).height * 0.3).clamp(
                  80,
                  280,
                ),
                child: ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        item.state == _DownloadState.saved
                            ? Icons.check_circle_outline
                            : item.state == _DownloadState.failed
                            ? Icons.error_outline
                            : item.state == _DownloadState.skipped
                            ? Icons.skip_next_outlined
                            : Icons.downloading_outlined,
                      ),
                      title: Text('#${item.post.id} · ${_label(item.state)}'),
                      subtitle: item.message == null
                          ? null
                          : Text(item.message!),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_running)
            TextButton(
              onPressed: _cancelRequested ? null : _cancel,
              child: const Text('取消下载'),
            )
          else ...[
            if (_unfinished.isNotEmpty)
              TextButton(onPressed: _run, child: const Text('重试未完成项')),
            FilledButton(onPressed: _close, child: const Text('完成')),
          ],
        ],
      ),
    );
  }
}
