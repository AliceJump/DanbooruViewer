enum NetworkMode { direct, environment, http, socks5 }

/// Only endpoint information is persisted. Authenticated proxies are not yet
/// supported, so credentials can never accidentally enter preferences/logs.
class NetworkSettings {
  const NetworkSettings({
    this.mode = NetworkMode.environment,
    this.host = '127.0.0.1',
    this.port = 10808,
  });

  final NetworkMode mode;
  final String host;
  final int port;

  bool get usesManualProxy =>
      mode == NetworkMode.http || mode == NetworkMode.socks5;

  String get normalizedHost {
    final value = host.trim();
    return (value.startsWith('[') && value.endsWith(']')
            ? value.substring(1, value.length - 1)
            : value)
        .toLowerCase();
  }

  String? validate() {
    final hostError = validateHost(host);
    if (hostError != null) return hostError;
    if (port < 1 || port > 65535) return '端口必须为 1–65535 的整数。';
    return null;
  }

  static String? validateHost(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return '请输入代理主机，例如 127.0.0.1。';
    if (RegExp(r'[\s/@?#\\]').hasMatch(raw) || raw.contains('://')) {
      return '只填写主机或 IP，不要包含协议、端口、路径或账号密码。';
    }
    final host = raw.startsWith('[') && raw.endsWith(']')
        ? raw.substring(1, raw.length - 1)
        : raw;
    if ((raw.contains('[') || raw.contains(']')) && !host.contains(':')) {
      return '方括号仅用于 IPv6 地址。';
    }
    if (host.contains(':')) {
      try {
        final uri = Uri.parse('http://[$host]/');
        if (uri.host.isNotEmpty && !host.contains('%')) return null;
      } on FormatException {
        // Fall through to the same field-specific validation message.
      }
      return '请输入有效 IPv6 地址，端口请填写在下方。';
    }
    if (host.length > 253 || !RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host)) {
      return '请输入有效主机名、IPv4 或 IPv6 地址。';
    }
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) {
      if (host
          .split('.')
          .any(
            (part) => part.length > 3 || (int.tryParse(part) ?? 256) > 255,
          )) {
        return 'IPv4 地址每段必须在 0–255 之间。';
      }
      return null;
    }
    final labels = host.endsWith('.')
        ? host.substring(0, host.length - 1).split('.')
        : host.split('.');
    if (labels.any(
      (label) =>
          label.isEmpty ||
          label.length > 63 ||
          label.startsWith('-') ||
          label.endsWith('-'),
    )) {
      return '请输入有效主机名。';
    }
    return null;
  }

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'host': normalizedHost,
    'port': port,
  };

  factory NetworkSettings.fromJson(Map<String, dynamic> json) {
    final mode = NetworkMode.values.where((mode) => mode.name == json['mode']);
    if (mode.isEmpty || json['host'] is! String || json['port'] is! int) {
      throw const FormatException('无效网络设置');
    }
    final settings = NetworkSettings(
      mode: mode.first,
      host: json['host'] as String,
      port: json['port'] as int,
    );
    if (settings.validate() != null) {
      throw const FormatException('无效代理地址');
    }
    return settings;
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkSettings &&
      other.mode == mode &&
      other.normalizedHost == normalizedHost &&
      other.port == port;

  @override
  int get hashCode => Object.hash(mode, normalizedHost, port);
}
