import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network_errors.dart';
import 'network_settings.dart';
import 'socks5_connection.dart';

http.Client createNetworkClient(NetworkSettings settings) =>
    _createNetworkClient(settings, null);

/// Allows local TLS regression fixtures without changing production trust.
@visibleForTesting
http.Client createNetworkClientForTesting(
  NetworkSettings settings, {
  required SecurityContext securityContext,
}) => _createNetworkClient(settings, securityContext);

http.Client _createNetworkClient(
  NetworkSettings settings,
  SecurityContext? context,
) {
  final error = settings.validate();
  if (error != null) throw NetworkException(NetworkErrorKind.proxy, error);
  final client = HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = 4;
  final host = settings.normalizedHost.contains(':')
      ? '[${settings.normalizedHost}]'
      : settings.normalizedHost;
  client.findProxy = (uri) {
    // Dart skips its scheme check when a connectionFactory is installed.
    // findProxy runs for every redirect, even if its connection is reused.
    validateNetworkUri(uri);
    return switch (settings.mode) {
      NetworkMode.direct || NetworkMode.socks5 => 'DIRECT',
      NetworkMode.environment => environmentProxyFor(uri, Platform.environment),
      NetworkMode.http => 'PROXY $host:${settings.port}',
    };
  };
  if (settings.mode == NetworkMode.socks5) {
    final attempts = <Socks5ConnectionAttempt>{};
    client.connectionFactory = (uri, _, _) {
      final attempt = Socks5ConnectionAttempt(settings, uri, context: context);
      attempts.add(attempt);
      return Future.value(attempt.task);
    };
    return _SocksClient(IOClient(client), attempts);
  }
  return IOClient(client);
}

/// Matches Dart's process-environment HTTP proxy selection (including
/// NO_PROXY); it does not claim to read OS/PAC settings. Unsupported schemes
/// and authentication are rejected instead of silently changing their meaning.
String environmentProxyFor(Uri uri, Map<String, String> environment) {
  final result = HttpClient.findProxyFromEnvironment(
    uri,
    environment: environment,
  );
  if (result == 'DIRECT') return result;
  final key = uri.scheme == 'https' ? 'https_proxy' : 'http_proxy';
  final configured = (environment[key] ?? environment[key.toUpperCase()])
      ?.trim();
  if (configured == null || configured.isEmpty) return result;
  final parsed = Uri.tryParse(
    configured.contains('://') ? configured : 'http://$configured',
  );
  if (parsed == null ||
      parsed.scheme != 'http' ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      (parsed.path.isNotEmpty && parsed.path != '/') ||
      NetworkSettings.validateHost(parsed.host) != null ||
      (parsed.hasPort && (parsed.port < 1 || parsed.port > 65535))) {
    throw const NetworkException(
      NetworkErrorKind.proxy,
      '环境代理格式不受支持；请使用无认证 HTTP 代理，或在设置中选择 HTTP / SOCKS5。',
    );
  }
  return result;
}

NetworkException classifyNetworkError(Object error, NetworkSettings settings) {
  if (error is NetworkException) return error;
  if (error is HandshakeException || error is TlsException) {
    return const NetworkException(
      NetworkErrorKind.tls,
      '安全连接验证失败，请检查设备时间、代理证书和服务器证书。',
    );
  }
  if (settings.usesManualProxy) {
    return const NetworkException(
      NetworkErrorKind.proxy,
      '代理连接失败，请确认代理已启动、主机和端口正确，且所选协议匹配。',
    );
  }
  return const NetworkException(
    NetworkErrorKind.connection,
    '无法连接服务器，请检查网络、代理或 DNS 后重试。',
  );
}

class _SocksClient extends http.BaseClient {
  _SocksClient(this._inner, this._attempts);
  final http.Client _inner;
  final Set<Socks5ConnectionAttempt> _attempts;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    for (final attempt in _attempts) {
      attempt.cancel();
    }
    _attempts.clear();
    _inner.close();
  }
}
