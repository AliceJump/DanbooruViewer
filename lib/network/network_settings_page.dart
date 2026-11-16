import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_network_service.dart';

class NetworkSettingsPage extends StatefulWidget {
  const NetworkSettingsPage({super.key, this.service, this.browserManaged});

  final AppNetworkService? service;
  @visibleForTesting
  final bool? browserManaged;

  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController();
  late final AppNetworkService _service;
  NetworkMode _mode = NetworkMode.environment;
  bool _ready = false;
  bool _saving = false;
  String? _saveError;
  String? _testing;
  NetworkCancelToken? _probeToken;
  NetworkProbeResult? _apiResult;
  NetworkProbeResult? _cdnResult;

  bool get _browserManaged => widget.browserManaged ?? kIsWeb;
  bool get _manual => _mode == NetworkMode.http || _mode == NetworkMode.socks5;
  NetworkSettings get _draft {
    final draft = NetworkSettings(
      mode: _mode,
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 0,
    );
    // Discard an invalid manual endpoint when the user explicitly switches
    // away from manual proxying; credentials never enter saved preferences.
    return !_manual && draft.validate() != null
        ? NetworkSettings(mode: _mode)
        : draft;
  }

  bool get _dirty => !_browserManaged && _draft != _service.settings;

  static final _sampleUri = Uri.https('danbooru.donmai.us', '/posts.json', {
    'limit': '1',
    'tags': 'rating:g',
  });

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AppNetworkService.instance;
    _load();
  }

  Future<void> _load() async {
    await _service.initialize();
    if (!mounted) return;
    final settings = _service.settings;
    setState(() {
      _mode = settings.mode;
      _host.text = settings.host;
      _port.text = settings.port.toString();
      _ready = true;
    });
  }

  @override
  void dispose() {
    _probeToken?.cancel();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_browserManaged && !(_form.currentState?.validate() ?? false)) return;
    _probeToken?.cancel();
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await _service.updateSettings(
        _browserManaged ? const NetworkSettings() : _draft,
      );
      if (!mounted) return;
      setState(() {
        _apiResult = null;
        _cdnResult = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('网络设置已保存，新请求将使用此设置。')));
    } catch (error) {
      if (mounted) {
        setState(
          () => _saveError = error is NetworkException
              ? error.message
              : '保存失败，请稍后重试。当前连接设置未更改。',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection(bool cdn) async {
    if (_testing != null || _dirty) return;
    final token = NetworkCancelToken();
    _probeToken = token;
    setState(() {
      _testing = cdn ? 'cdn' : 'api';
    });
    final result = cdn
        ? await _testCdn(token)
        : await _service.probe(_sampleUri, cancelToken: token);
    if (!mounted || token.isCancelled) return;
    setState(() {
      if (cdn) {
        _cdnResult = result;
      } else {
        _apiResult = result;
      }
      _testing = null;
    });
  }

  Future<NetworkProbeResult> _testCdn(NetworkCancelToken token) async {
    final watch = Stopwatch()..start();
    try {
      final response = await _service.get(
        _sampleUri,
        cancelToken: token,
        timeout: const Duration(seconds: 15),
        retry: false,
      );
      if (response.statusCode != 200) {
        return NetworkProbeResult(
          host: '图片 CDN',
          elapsed: watch.elapsed,
          succeeded: false,
          statusCode: response.statusCode,
          message: '获取图片样本失败（API 返回 HTTP ${response.statusCode}），尚未测试 CDN。',
        );
      }
      final posts = jsonDecode(response.body);
      String? preview;
      if (posts is List) {
        for (final post in posts) {
          if (post is Map && post['preview_file_url'] is String) {
            preview = post['preview_file_url'] as String;
            break;
          }
        }
      }
      final uri = preview == null ? null : Uri.tryParse(preview);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        return NetworkProbeResult(
          host: '图片 CDN',
          elapsed: watch.elapsed,
          succeeded: false,
          message: 'API 未返回可测试的图片地址，请稍后重试。',
        );
      }
      return _service.probe(uri, cancelToken: token);
    } catch (error) {
      return NetworkProbeResult(
        host: '图片 CDN',
        elapsed: watch.elapsed,
        succeeded: false,
        message: '获取图片样本失败，尚未测试 CDN。${networkErrorMessage(error)}',
      );
    }
  }

  void _cancelTest() {
    _probeToken?.cancel();
    setState(() => _testing = null);
  }

  String get _modeExplanation => switch (_mode) {
    NetworkMode.direct => '直接连接服务器，不使用应用代理或环境代理。',
    NetworkMode.environment =>
      '读取启动进程的 HTTP_PROXY、HTTPS_PROXY 和 NO_PROXY 环境变量。不读取系统代理或 PAC；没有匹配的环境变量时会直接连接。',
    NetworkMode.http => '通过指定 HTTP 代理连接；HTTPS 使用 CONNECT 隧道。代理不可用时会报错，不会自动直连。',
    NetworkMode.socks5 => '通过指定 SOCKS5 代理连接，目标域名由代理解析。代理不可用时会报错，不会自动直连。',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('网络设置')),
      body: SafeArea(
        child: !_ready
            ? const Center(child: CircularProgressIndicator())
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_service.configurationLoadError
                          case final error?) ...[
                        _errorBox(error.message),
                        const SizedBox(height: 16),
                      ],
                      Text('连接方式', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      if (_browserManaged) ...[
                        const Text(
                          '网页版使用浏览器网络。请在浏览器、操作系统或代理软件中配置代理；浏览器的跨域限制仍然适用。',
                        ),
                        if (_service.configurationLoadError != null) ...[
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _saving ? null : _save,
                            child: const Text('恢复浏览器网络配置'),
                          ),
                        ],
                      ] else
                        Form(
                          key: _form,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              DropdownButtonFormField<NetworkMode>(
                                key: const ValueKey('network-mode'),
                                initialValue: _mode,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '代理模式',
                                  border: OutlineInputBorder(),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: NetworkMode.environment,
                                    child: Text('环境变量'),
                                  ),
                                  DropdownMenuItem(
                                    value: NetworkMode.direct,
                                    child: Text('直接连接'),
                                  ),
                                  DropdownMenuItem(
                                    value: NetworkMode.http,
                                    child: Text('HTTP 代理'),
                                  ),
                                  DropdownMenuItem(
                                    value: NetworkMode.socks5,
                                    child: Text('SOCKS5 代理'),
                                  ),
                                ],
                                onChanged: _saving || _testing != null
                                    ? null
                                    : (mode) {
                                        if (mode != null) {
                                          setState(() => _mode = mode);
                                        }
                                      },
                              ),
                              const SizedBox(height: 12),
                              Text(_modeExplanation),
                              if (_manual) ...[
                                const SizedBox(height: 16),
                                TextFormField(
                                  key: const ValueKey('proxy-host'),
                                  controller: _host,
                                  decoration: const InputDecoration(
                                    labelText: '代理主机',
                                    hintText: '127.0.0.1',
                                    helperText:
                                        '本机代理通常使用 127.0.0.1；也支持局域网主机与 IPv6。',
                                    helperMaxLines: 3,
                                    errorMaxLines: 4,
                                    border: OutlineInputBorder(),
                                  ),
                                  keyboardType: TextInputType.url,
                                  autocorrect: false,
                                  enabled: !_saving && _testing == null,
                                  validator: (value) =>
                                      NetworkSettings.validateHost(value ?? ''),
                                  onChanged: (_) => setState(() {}),
                                  textInputAction: TextInputAction.next,
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  key: const ValueKey('proxy-port'),
                                  controller: _port,
                                  decoration: const InputDecoration(
                                    labelText: '代理端口',
                                    hintText: '10808',
                                    helperText: '填写代理软件对应协议的监听端口。',
                                    helperMaxLines: 3,
                                    errorMaxLines: 3,
                                    border: OutlineInputBorder(),
                                  ),
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  enabled: !_saving && _testing == null,
                                  validator: (value) {
                                    final port = int.tryParse(value ?? '');
                                    return port == null ||
                                            port < 1 ||
                                            port > 65535
                                        ? '端口必须为 1–65535 的整数。'
                                        : null;
                                  },
                                  onChanged: (_) => setState(() {}),
                                  onFieldSubmitted: (_) => _save(),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  '当前支持无需账号密码的代理。应用不会保存代理密码，也不会忽略 HTTPS 证书错误。',
                                ),
                              ],
                              const SizedBox(height: 16),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton.icon(
                                  key: const ValueKey('save-network'),
                                  onPressed: _saving || _testing != null
                                      ? null
                                      : _save,
                                  icon: const Icon(Icons.save_outlined),
                                  label: Text(_saving ? '保存中…' : '保存设置'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_saveError case final error?) ...[
                        const SizedBox(height: 12),
                        _errorBox(error),
                      ],
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 16),
                      Text('连接检查', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(
                        _dirty
                            ? '请先保存设置，再测试当前连接。'
                            : 'API 与图片 CDN 分别检查。检查只读取少量数据，不下载完整图片。',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _testing != null || _dirty || _saving
                                ? null
                                : () => _testConnection(false),
                            icon: const Icon(Icons.cloud_outlined),
                            label: const Text('测试 API'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _testing != null || _dirty || _saving
                                ? null
                                : () => _testConnection(true),
                            icon: const Icon(Icons.image_outlined),
                            label: const Text('测试图片 CDN'),
                          ),
                          if (_testing != null)
                            TextButton(
                              onPressed: _cancelTest,
                              child: const Text('取消检查'),
                            ),
                        ],
                      ),
                      if (_testing != null) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(
                          _testing == 'cdn' ? '正在获取图片样本并测试 CDN…' : '正在测试 API…',
                        ),
                      ],
                      if (_apiResult case final result?)
                        _resultTile('API', result),
                      if (_cdnResult case final result?)
                        _resultTile('图片 CDN', result),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _errorBox(String message) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    ),
  );

  Widget _resultTile(String label, NetworkProbeResult result) => Semantics(
    liveRegion: true,
    child: Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              result.succeeded
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              color: result.succeeded
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$label：${result.succeeded ? '连接成功' : '连接失败'}\n${result.host} · ${result.elapsed.inMilliseconds} 毫秒${result.statusCode == null ? '' : ' · HTTP ${result.statusCode}'}${result.message == null ? '' : '\n${result.message}'}',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
